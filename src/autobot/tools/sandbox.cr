require "log"
require "base64"

module Autobot
  module Tools
    # Kernel-enforced sandboxing for command execution
    # Uses bubblewrap or Docker to restrict file access at OS level
    class Sandbox
      Log = ::Log.for(self)

      TIMEOUT_EXIT_CODE     =  124
      IO_BUFFER_SIZE        = 4096
      SIGNAL_GRACE_PERIOD   = 0.5.seconds
      DOCKER_MEMORY_LIMIT   = "512m"
      DOCKER_CPU_LIMIT      = "1"
      DOCKER_DEFAULT_IMAGE  = "alpine:latest"
      DEFAULT_MAX_FILE_SIZE = 1_000_000
      READ_FILE_TIMEOUT     =        10
      WRITE_FILE_TIMEOUT    =        30
      LIST_DIR_TIMEOUT      =        10
      MKDIR_TIMEOUT         =         5
      MAX_WRITE_OUTPUT      =    10_000
      MAX_LIST_OUTPUT       =   100_000

      enum Type
        Bubblewrap
        Docker
        None
      end

      # Test override for sandbox detection (set to nil to use real detection)
      class_property detect_override : Type? = nil

      # Custom Docker image (set from config at startup)
      class_property docker_image : String? = nil

      # Cached result of detect_type (avoids redundant subprocess calls)
      @@cached_type : Type? = nil

      # Detect available sandbox tool (memoized)
      def self.detect : Type
        if override = @@detect_override
          return override
        end
        @@cached_type ||= detect_type
      end

      private def self.detect_type : Type
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

      # Resolve sandbox type from config string
      def self.resolve_type(config : String) : Type
        case config.downcase
        when "bubblewrap" then Type::Bubblewrap
        when "docker"     then Type::Docker
        when "none"       then Type::None
        when "auto"       then detect
        else
          raise ArgumentError.new(
            "Invalid sandbox config: #{config}. Use 'auto', 'bubblewrap', 'docker', or 'none'"
          )
        end
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

      private def self.exec_bubblewrap(
        command : String,
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32,
      ) : {Process::Status, String, String}
        workspace_real = File.realpath(workspace.to_s)

        bwrap_args = [
          "--ro-bind", "/usr", "/usr",
          "--ro-bind", "/lib", "/lib",
          "--ro-bind", "/bin", "/bin",
          "--ro-bind", "/sbin", "/sbin",
          "--bind", workspace_real, workspace_real,
          "--proc", "/proc",
          "--dev", "/dev",
          "--unshare-all",
          "--share-net",
          "--die-with-parent",
          "--chdir", workspace_real,
        ]
        bwrap_args.push("--ro-bind", "/lib64", "/lib64") if Dir.exists?("/lib64")
        bwrap_args.push("--tmpfs", "/tmp")
        bwrap_args.push("--", "sh", "-c", command)

        Log.debug { "Executing in bubblewrap: #{command}" }
        run_sandboxed_command("bwrap", bwrap_args, timeout, max_output_size)
      end

      private def self.exec_docker(
        command : String,
        workspace : Path,
        timeout : Int32,
        max_output_size : Int32,
      ) : {Process::Status, String, String}
        workspace_real = File.realpath(workspace.to_s)

        docker_args = [
          "run",
          "--rm",
          "-v", "#{workspace_real}:#{workspace_real}:rw",
          "-w", workspace_real,
          "--network", "bridge",
          "--memory", DOCKER_MEMORY_LIMIT,
          "--cpus", DOCKER_CPU_LIMIT,
          @@docker_image || DOCKER_DEFAULT_IMAGE,
          "sh", "-c", command,
        ]

        Log.debug { "Executing in Docker: #{command}" }
        run_sandboxed_command("docker", docker_args, timeout, max_output_size)
      end

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

        stdout_channel = Channel(String).new(1)
        stderr_channel = Channel(String).new(1)

        spawn { stdout_channel.send(read_limited_output(stdout_read, max_output_size)) }
        spawn { stderr_channel.send(read_limited_output(stderr_read, max_output_size)) }

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
            Process::Status.new(TIMEOUT_EXIT_CODE)
          end
        end
      end

      def self.read_file(path : String, workspace : Path, max_size : Int32 = DEFAULT_MAX_FILE_SIZE) : {Bool, String}
        command = "cat #{shell_escape(path)} 2>&1"
        status, stdout, stderr = exec(command, workspace, timeout: READ_FILE_TIMEOUT, max_output_size: max_size)

        {status.success?, status.success? ? stdout : stderr}
      end

      def self.write_file(path : String, content : String, workspace : Path) : {Bool, String}
        dir = File.dirname(path)
        if dir != "." && dir != "/"
          mkdir_status, _, mkdir_err = exec("mkdir -p #{shell_escape(dir)}", workspace, timeout: MKDIR_TIMEOUT)
          return {false, mkdir_err} unless mkdir_status.success?
        end

        # Base64 encoding prevents shell escaping issues with special characters
        encoded = Base64.strict_encode(content)
        command = "printf '%s' '#{encoded}' | base64 -d > #{shell_escape(path)} 2>&1"
        status, _, stderr = exec(command, workspace, timeout: WRITE_FILE_TIMEOUT, max_output_size: MAX_WRITE_OUTPUT)

        message = status.success? ? "Wrote #{content.bytesize} bytes" : stderr
        {status.success?, message}
      end

      def self.list_dir(path : String, workspace : Path) : {Bool, String}
        command = "ls -1a #{shell_escape(path)} 2>&1"
        status, stdout, stderr = exec(command, workspace, timeout: LIST_DIR_TIMEOUT, max_output_size: MAX_LIST_OUTPUT)

        {status.success?, status.success? ? stdout : stderr}
      end

      def self.shell_escape(arg : String) : String
        "'#{arg.gsub("'", "'\\''")}'"
      end

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

        • bubblewrap (recommended for Linux):
            Ubuntu/Debian: sudo apt install bubblewrap
            Fedora:        sudo dnf install bubblewrap
            Arch:          sudo pacman -S bubblewrap

        • Docker (required for macOS, universal):
            macOS:         https://docs.docker.com/desktop/install/mac-install/
            Linux:         sudo apt install docker.io
            Others:        https://docs.docker.com/engine/install/

        Learn more: docs/sandboxing.md
        ERROR
      end
    end
  end
end
