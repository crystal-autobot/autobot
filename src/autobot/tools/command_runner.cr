module Autobot
  module Tools
    # Runs a process with a timeout, capturing size-limited stdout and stderr.
    module CommandRunner
      IO_BUFFER_SIZE      = 4096
      SIGNAL_GRACE_PERIOD = 0.5.seconds
      DEFAULT_MAX_OUTPUT  = 10_000

      record Result, status : Process::Status?, stdout : String, stderr : String do
        def timed_out? : Bool
          status.nil?
        end

        def success? : Bool
          status.try(&.success?) || false
        end

        def exit_code : Int32?
          status.try { |status| status.exit_code if status.normal_exit? }
        end
      end

      # The read ends are closed once the process settles so reader fibers never
      # block on daemons that inherit and keep the pipe write ends open.
      def self.run(
        command : String,
        args : Array(String),
        timeout : Int32,
        max_output_size : Int32 = DEFAULT_MAX_OUTPUT,
      ) : Result
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe

        process = Process.new(
          command,
          args,
          output: stdout_write,
          error: stderr_write,
        )

        stdout_write.close
        stderr_write.close

        stdout_channel = Channel(String).new(1)
        stderr_channel = Channel(String).new(1)

        spawn { stdout_channel.send(read_limited_output(stdout_read, max_output_size)) }
        spawn { stderr_channel.send(read_limited_output(stderr_read, max_output_size)) }

        completed = Channel(Process::Status).new(1)
        spawn { completed.send(process.wait) }

        status = wait_for_process(process, completed, timeout)

        stdout_read.close unless stdout_read.closed?
        stderr_read.close unless stderr_read.closed?

        Result.new(status, stdout_channel.receive, stderr_channel.receive)
      end

      private def self.read_limited_output(io : IO, max_size : Int32) : String
        buffer = IO::Memory.new
        bytes_read = 0
        chunk = Bytes.new(IO_BUFFER_SIZE)

        while (n = io.read(chunk)) > 0
          bytes_read += n
          if bytes_read > max_size
            buffer.write(chunk[0, Math.max(0, max_size - (bytes_read - n))])
            buffer << "\n... (output truncated at #{max_size} bytes)"
            # Drain the rest instead of closing the pipe: closing the read end
            # sends SIGPIPE to a still-running child and can kill it before its
            # side effects finish. The parent closes read ends after the process
            # exits, which unblocks this drain for detached/daemon writers.
            io.skip_to_end
            break
          end
          buffer.write(chunk[0, n])
        end

        buffer.to_s
      rescue
        buffer.to_s
      end

      private def self.wait_for_process(
        process : Process,
        completed : Channel(Process::Status),
        timeout : Int32,
      ) : Process::Status?
        select
        when status = completed.receive
          status
        when timeout(timeout.seconds)
          terminate(process, completed)
          nil
        end
      end

      private def self.terminate(process : Process, completed : Channel(Process::Status)) : Nil
        process.signal(Signal::TERM)

        select
        when completed.receive
        when timeout(SIGNAL_GRACE_PERIOD)
          process.signal(Signal::KILL)
          completed.receive
        end
      rescue RuntimeError
        # signalling fails once the process has already exited
      end
    end
  end
end
