require "log"

module Autobot
  module Tools
    # Kernel-enforced sandboxing for command execution
    # Uses bubblewrap or Docker to restrict file access at OS level
    class Sandbox
      Log = ::Log.for(self)

      # Constants
      TIMEOUT_EXIT_CODE    =  124            # Standard timeout exit code (used by timeout command)
      IO_BUFFER_SIZE       = 4096            # Bytes per read chunk
      SIGNAL_GRACE_PERIOD  = 0.5.seconds     # Time to wait between TERM and KILL signals
      DOCKER_MEMORY_LIMIT  = "512m"          # Memory limit for Docker containers
      DOCKER_CPU_LIMIT     = "1"             # CPU limit for Docker containers
      DOCKER_DEFAULT_IMAGE = "alpine:latest" # Minimal Linux image for sandboxing

      enum Type
        Bubblewrap
        Docker
        None
      end

      # Detect available sandbox tool
      def self.detect : Type
        if command_exists?("bwrap")
          Type::Bubblewrap
        elsif command_exists?("docker")
          Type::Docker
        else
          Type::None
        end
      end

      # Check if sandboxing is available
      def self.available? : Bool
        detect != Type::None
      end

      # Require sandbox or raise clear error
      def self.require_sandbox! : Nil
        unless available?
          raise SandboxNotFoundError.new
        end
      end

      # Execute command in sandbox
      # Returns: {Process::Status, stdout, stderr}
      def self.exec(
        command : String,
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32 = 10_000,
      ) : {Process::Status, String, String}
        sandbox_type = detect

        case sandbox_type
        when Type::Bubblewrap
          exec_bubblewrap(command, workspace, timeout, max_output_size)
        when Type::Docker
          exec_docker(command, workspace, timeout, max_output_size)
        else
          raise SandboxNotFoundError.new
        end
      end

      # Execute via bubblewrap (lightweight namespace isolation)
      private def self.exec_bubblewrap(
        command : String,
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32,
      ) : {Process::Status, String, String}
        workspace_real = File.realpath(workspace.to_s)

        # Build bwrap command
        bwrap_args = [
          # System binaries (read-only)
          "--ro-bind", "/usr", "/usr",
          "--ro-bind", "/lib", "/lib",
          "--ro-bind", "/lib64", "/lib64",
          "--ro-bind", "/bin", "/bin",
          "--ro-bind", "/sbin", "/sbin",

          # Workspace (read-write) - ONLY this directory is writable
          "--bind", workspace_real, workspace_real,

          # Essential system directories
          "--proc", "/proc",
          "--dev", "/dev",
          "--tmpfs", "/tmp",

          # Isolation
          "--unshare-all",
          "--share-net",
          "--die-with-parent",

          # Working directory
          "--chdir", workspace_real,

          # Execute command
          "--", "sh", "-c", command,
        ]

        Log.debug { "Executing in bubblewrap: #{command}" }
        run_sandboxed_command("bwrap", bwrap_args, timeout, max_output_size)
      end

      # Execute via Docker (full container isolation)
      private def self.exec_docker(
        command : String,
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32,
      ) : {Process::Status, String, String}
        workspace_real = File.realpath(workspace.to_s)

        # Build docker command
        docker_args = [
          "run",
          "--rm",                                         # Remove container after execution
          "-v", "#{workspace_real}:#{workspace_real}:rw", # Mount workspace
          "-w", workspace_real,                           # Working directory
          "--network", "bridge",                          # Network access
          "--memory", DOCKER_MEMORY_LIMIT,                # Memory limit
          "--cpus", DOCKER_CPU_LIMIT,                     # CPU limit
          DOCKER_DEFAULT_IMAGE,                           # Minimal image
          "sh", "-c", command,
        ]

        Log.debug { "Executing in Docker: #{command}" }
        run_sandboxed_command("docker", docker_args, timeout, max_output_size)
      end

      # Run sandboxed command with timeout and output limits
      private def self.run_sandboxed_command(
        sandbox_cmd : String,
        args : Array(String),
        timeout : Int32,
        max_output_size : Int32,
      ) : {Process::Status, String, String}
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe

        process = Process.new(
          sandbox_cmd,
          args,
          output: stdout_write,
          error: stderr_write
        )

        stdout_write.close
        stderr_write.close

        # Read output with size limits
        stdout_channel = Channel(String).new(1)
        stderr_channel = Channel(String).new(1)

        spawn { stdout_channel.send(read_limited_output(stdout_read, max_output_size)) }
        spawn { stderr_channel.send(read_limited_output(stderr_read, max_output_size)) }

        # Wait for completion with timeout
        completed = Channel(Process::Status).new(1)
        spawn do
          status = process.wait
          completed.send(status)
        end

        status = wait_for_process(process, completed, timeout)

        stdout_text = stdout_channel.receive
        stderr_text = stderr_channel.receive

        stdout_read.close
        stderr_read.close

        {status, stdout_text, stderr_text}
      end

      # Read output with size limit
      private def self.read_limited_output(io : IO, max_size : Int32) : String
        buffer = IO::Memory.new
        bytes_read = 0
        chunk = Bytes.new(IO_BUFFER_SIZE)

        while (n = io.read(chunk)) > 0
          bytes_read += n
          if bytes_read > max_size
            buffer.write(chunk[0, Math.max(0, max_size - (bytes_read - n))])
            buffer << "\n... (output truncated at #{max_size} bytes)"
            break
          end
          buffer.write(chunk[0, n])
        end

        buffer.to_s
      rescue
        ""
      end

      # Wait for process with timeout
      private def self.wait_for_process(
        process : Process,
        completed : Channel(Process::Status),
        timeout : Int32,
      ) : Process::Status
        select
        when status = completed.receive
          status
        when timeout(timeout.seconds)
          begin
            process.signal(Signal::TERM)
            sleep SIGNAL_GRACE_PERIOD
            process.signal(Signal::KILL) unless process.terminated?
            status = process.wait
            status
          rescue
            # Process already terminated, create a timeout status
            Process::Status.new(TIMEOUT_EXIT_CODE)
          end
        end
      end

      # Check if command exists in PATH
      private def self.command_exists?(cmd : String) : Bool
        Process.run("which", [cmd], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
      rescue
        false
      end
    end

    # Exception raised when sandbox tools are not available
    class SandboxNotFoundError < Exception
      def initialize
        super(build_error_message)
      end

      private def build_error_message : String
        <<-ERROR
        ╔══════════════════════════════════════════════════════════╗
        ║  SECURITY ERROR: No sandbox tool found                   ║
        ╚══════════════════════════════════════════════════════════╝

        Autobot requires sandboxing to safely restrict LLM file access.

        Install one of:

        • bubblewrap (recommended, lightweight):
            Ubuntu/Debian: sudo apt install bubblewrap
            Fedora:        sudo dnf install bubblewrap
            Arch:          sudo pacman -S bubblewrap

        • Docker (production):
            Ubuntu/Debian: sudo apt install docker.io
            Others:        https://docs.docker.com/engine/install/

        Learn more: docs/security.md#sandboxing
        ERROR
      end
    end
  end
end
