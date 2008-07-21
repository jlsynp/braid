require 'singleton'
require 'rubygems'
require 'open4'

module Braid
  module Operations
    class ShellExecutionError < BraidError
    end
    class VersionTooLow < BraidError
    end
    class UnknownRevision < BraidError
    end
    class LocalChangesPresent < BraidError
    end

    # The command proxy is meant to encapsulate commands such as git, git-svn and svn, that work with subcommands.
    class Proxy
      include Singleton

      def self.command; name.split('::').last.downcase; end # hax!

      def version
        status, out, err = exec!("#{self.class.command} --version")
        out.sub(/^.* version/, "").strip
      end

      def require_version(required)
        required = required.split(".")
        actual = version.split(".")

        actual.each_with_index do |actual_piece, idx|
          required_piece = required[idx]

          return true unless required_piece

          case (actual_piece <=> required_piece)
            when -1
              return false
            when 1
              return true
            when 0
              next
          end
        end

        return actual.length >= required.length
      end

      def require_version!(required)
        require_version(required) || raise(VersionTooLow, version)
      end

      private
        def command(name)
          # stub
          name
        end

        def invoke(arg, *args)
          exec!("#{command(arg)} #{args.join(' ')}".strip)[1] # return stdout
        end

        def method_missing(name, *args)
          invoke(name, *args)
        end

        def exec(cmd)
          cmd.strip!

          previous_lang = ENV['LANG']
          ENV['LANG'] = 'C'

          out, err = nil
          status = Open4.popen4(cmd) do |pid, stdin, stdout, stderr|
            out = stdout.read.strip
            err = stderr.read.strip
          end.exitstatus
          [status, out, err]

        ensure
          ENV['LANG'] = previous_lang
        end

        def exec!(cmd)
          status, out, err = exec(cmd)
          raise ShellExecutionError, err unless status == 0
          [status, out, err]
        end
    end

    class Git < Proxy
      def commit(message)
        status, out, err = exec("git commit -m #{message.inspect} --no-verify")

        if status == 0
          true
        elsif out.match(/nothing.* to commit/)
          false
        else
          raise ShellExecutionError, err
        end
      end

      def fetch(remote)
        # open4 messes with the pipes of index-pack
        system("git fetch -n #{remote} &> /dev/null")
        raise ShellExecutionError unless $? == 0
        true
      end

      def checkout(treeish)
        # TODO debug
        msg "Checking out '#{treeish}'."
        invoke(:checkout, treeish)
        true
      end

      # Returns the base commit or nil.
      def merge_base(target, source)
        invoke(:merge_base, target, source)
      rescue ShellExecutionError
        nil
      end

      def rev_parse(opt)
        invoke(:rev_parse, opt)
      rescue ShellExecutionError
        raise UnknownRevision, opt
      end

      # Implies tracking.
      def remote_add(remote, path, branch)
        invoke(:remote, "add", "-t #{branch} -m #{branch}", remote, path)
        true
      end

      # Checks git and svn remotes.
      def remote_exists?(remote)
        # TODO clean up and maybe return more information
        !!File.readlines(".git/config").find { |line| line =~ /^\[(svn-)?remote "#{remote}"\]/ }
      end

      def reset_hard(target)
        invoke(:reset, "--hard", target)
        true
      end

      # Implies no commit.
      def merge_ours(opt)
        invoke(:merge, "-s ours --no-commit", opt)
        true
      end

      # Implies no commit.
      def merge_subtree(opt)
        # TODO which options are needed?
        invoke(:merge, "-s subtree --no-commit --no-ff", opt)
        true
      end

      def read_tree(treeish, prefix)
        invoke(:read_tree, "--prefix=#{prefix}/ -u", treeish)
        true
      end

      def rm_r(path)
        invoke(:rm, "-r", path)
        true
      end

      def tree_hash(path, treeish = "HEAD")
        out = invoke(:ls_tree, treeish, "-d", path)
        out.split[2]
      end

      def diff_tree(src_tree, dst_tree, prefix = nil)
        cmd = "git diff-tree -p --binary #{src_tree} #{dst_tree}"
        cmd << " --src-prefix=a/#{prefix}/ --dst-prefix=b/#{prefix}/" if prefix
        status, out, err = exec!(cmd)
        out
      end

      def status_clean?
        status, out, err = exec("git status")
        !out.split("\n").grep(/nothing to commit \(working directory clean\)/).empty?
      end

      def ensure_clean!
        status_clean? || raise(LocalChangesPresent)
      end

      def head
        rev_parse("HEAD")
      end

      def branch
        status, out, err = exec!("git branch | grep '*'")
        out[2..-1]
      end

      def apply(diff)
        # always uses index
        status = Open4.popen4("git apply --index -") do |pid, stdin, stdout, stderr|
          stdin.puts(diff)
          stdin.close
        end.exitstatus
        raise ShellExecutionError unless status == 0
        true
      end

      private
        def command(name)
          "#{self.class.command} #{name.to_s.gsub('_', '-')}"
        end
    end

    class GitSvn < Proxy
      def self.command; "git-svn"; end

      def commit_hash(remote, revision)
        status, out, err = invoke(:log, "--show-commit --oneline", "-r #{revision}", remote)
        part = out.to_s.split(" | ")[1]
        raise UnknownRevision, "r#{revision}" unless part
        Git.instance.rev_parse(part) # FIXME ugly ugly ugly
      end

      def fetch(remote)
        # open4 messes with the pipes of index-pack
        system("git-svn fetch #{remote} &> /dev/null")
        true
      end

      def init(remote, path)
        invoke(:init, "-R", remote, "--id=#{remote}", path)
        true
      end

      private
        def command(name)
          "#{self.class.command} #{name}"
        end
    end

    class Svn < Proxy
      def clean_revision(revision)
        revision.to_i if revision
      end

      def head_revision(path)
        # not using svn info because it's retarded and doesn't show the actual last changed rev for the url
        # git svn has no clue on how to get the actual HEAD revision number on it's own
        status, out, err = exec!("svn log -q --limit 1 #{path}")
        out.split(/\n/).find { |x| x.match /^r\d+/ }.split(" | ")[0][1..-1].to_i
      end
    end

    module VersionControl
      def git
        Git.instance
      end

      def git_svn
        GitSvn.instance
      end

      def svn
        Svn.instance
      end
    end
  end
end
