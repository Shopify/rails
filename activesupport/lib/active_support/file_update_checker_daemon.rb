# frozen_string_literal: true

module ActiveSupport
  class FileUpdateCheckerDaemon
    def initialize(implementation, files, dirs = {}, &block)
      raise ArgumentError, "A block is required to initialize an EventedFileUpdateChecker" unless block

      @implementation = implementation
      @files = files
      @dirs = dirs
      @block = block
      @digest = Digest.hexdigest(Marshal.dump([Process.uid, files, dirs]))
      @pid_file = File.join(Dir.tmpdir, "active_support_file_update_checker-#{@digest}.pid")
      unless alive?
        start
      end
    end

    def updated?
      modified = File.mtime(@pid_file)
      modified > @last_modified
    rescue SystemCallError
      unless alive?
        start
        retry
      end
    end

    def execute
      @last_modified = Time.now
      @block.call
    end

    def execute_if_updated
      if updated?
        yield if block_given?
        execute
        true
      end
    end

    private

      def start
        @last_modified = Time.now
        child_read, parent_write = IO.pipe
        pid = Process.spawn([RbConfig.ruby, "rails_watch"], __FILE__, in: child_read)
        child_read.close
        Marshal.dump([@implementation.name, @pid_file, @files, @dirs], parent_write)
        parent_write.close
      end

      def alive?
        begin
          pid = File.read(@pid_file)
        rescue Errno::ENOENT
          return false
        end
        begin
          Process.kill(0, Integer(pid))
        rescue Errno::ESRCH
          File.unlink(@pid_file)
          false
        end
      end
  end
end

if __FILE__ == $0
  implementation, pid_file, files, dirs = Marshal.load($stdin)
  $stdin.close
  require "active_support"

  implementation = Object.const_get(implementation)
  begin
    pid_file = File.open(pid_file, "wx")
  rescue Errno::EEXIST
    exit
  end

  Process.fork do
    pid_file.write(Process.pid)
    pid_file.close
    at_exit { File.unlink(pid_file) }
    update_checker = implementation.new(files, dirs) do
      # TODO: stop if pid in pid_file doesn't match
      File.utime(nil, nil, pid_file) # touch
    end
    1_000.times do
      update_checker.execute_if_updated
      sleep 0.01
    end
  end
  sleep 1
  exit 0
end
