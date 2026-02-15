require "./result"
require "./sandbox"
require "./sandbox_service"

module Autobot
  module Tools
    # Centralized sandbox executor - all file and command operations must go through this
    # Prevents tools from bypassing sandboxing by using direct File.* operations
    #
    # Usage:
    #   executor = SandboxExecutor.new(sandbox_service, workspace)
    #   result = executor.read_file("test.txt")
    #   result = executor.exec("ls -la")
    class SandboxExecutor
      MAX_FILE_SIZE = 1_048_576

      def initialize(@sandbox_service : SandboxService?, @workspace : Path?)
      end

      def read_file(path : String) : ToolResult
        if service = @sandbox_service
          read_file_via_service(service, path)
        elsif workspace = @workspace
          read_file_via_sandbox_exec(path, workspace)
        else
          read_file_direct(path)
        end
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied: #{ex.message}")
      rescue ex
        ToolResult.error("Cannot read file: #{ex.message}")
      end

      def write_file(path : String, content : String) : ToolResult
        if service = @sandbox_service
          write_file_via_service(service, path, content)
        elsif workspace = @workspace
          write_file_via_sandbox_exec(path, content, workspace)
        else
          write_file_direct(path, content)
        end
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied: #{ex.message}")
      rescue ex
        ToolResult.error("Cannot write file: #{ex.message}")
      end

      def list_dir(path : String) : ToolResult
        if service = @sandbox_service
          list_dir_via_service(service, path)
        elsif workspace = @workspace
          list_dir_via_sandbox_exec(path, workspace)
        else
          list_dir_direct(path)
        end
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied: #{ex.message}")
      rescue ex
        ToolResult.error("Cannot list directory: #{ex.message}")
      end

      def exec(command : String, timeout : Int32 = 60) : ToolResult
        if service = @sandbox_service
          exec_via_service(service, command, timeout)
        elsif workspace = @workspace
          exec_via_sandbox_exec(command, timeout, workspace)
        else
          exec_direct(command, timeout)
        end
      rescue ex
        ToolResult.error("Cannot execute command: #{ex.message}")
      end

      # Service-based execution
      private def read_file_via_service(service : SandboxService, path : String) : ToolResult
        operation = SandboxService::Operation.new(
          type: SandboxService::OperationType::ReadFile,
          path: path
        )
        response = service.execute(operation)
        response.success? ? ToolResult.success(response.data || "") : ToolResult.error(response.error || "Unknown error")
      end

      private def write_file_via_service(service : SandboxService, path : String, content : String) : ToolResult
        operation = SandboxService::Operation.new(
          type: SandboxService::OperationType::WriteFile,
          path: path,
          content: content
        )
        response = service.execute(operation)
        response.success? ? ToolResult.success(response.data || "") : ToolResult.error(response.error || "Unknown error")
      end

      private def list_dir_via_service(service : SandboxService, path : String) : ToolResult
        operation = SandboxService::Operation.new(
          type: SandboxService::OperationType::ListDir,
          path: path
        )
        response = service.execute(operation)
        response.success? ? ToolResult.success(response.data || "") : ToolResult.error(response.error || "Unknown error")
      end

      private def exec_via_service(service : SandboxService, command : String, timeout : Int32) : ToolResult
        operation = SandboxService::Operation.new(
          type: SandboxService::OperationType::Exec,
          command: command,
          timeout: timeout
        )
        response = service.execute(operation)
        response.success? ? ToolResult.success(response.data || "") : ToolResult.error(response.error || "Unknown error")
      end

      # Sandbox.exec-based execution
      private def read_file_via_sandbox_exec(path : String, workspace : Path) : ToolResult
        success, output = Sandbox.read_file(path, workspace)
        success ? ToolResult.success(output) : ToolResult.error(output)
      end

      private def write_file_via_sandbox_exec(path : String, content : String, workspace : Path) : ToolResult
        success, output = Sandbox.write_file(path, content, workspace)
        success ? ToolResult.success(output) : ToolResult.error(output)
      end

      private def list_dir_via_sandbox_exec(path : String, workspace : Path) : ToolResult
        success, output = Sandbox.list_dir(path, workspace)
        return ToolResult.error(output) unless success

        entries = output.split("\n").reject(&.empty?).reject { |e| e == "." || e == ".." }.sort!
        return ToolResult.success("Directory is empty") if entries.empty?

        ToolResult.success(entries.join("\n"))
      end

      private def exec_via_sandbox_exec(command : String, timeout : Int32, workspace : Path) : ToolResult
        status, stdout, stderr = Sandbox.exec(command, workspace, timeout)

        parts = [] of String
        parts << stdout unless stdout.empty?
        parts << "STDERR:\n#{stderr}" unless stderr.empty?

        if !status.success? && status.exit_code != Sandbox::TIMEOUT_EXIT_CODE
          parts << "\nExit code: #{status.exit_code}"
        end

        data = parts.empty? ? "[no output]" : parts.join("\n")
        ToolResult.success(data)
      end

      # Direct execution (tests only)
      private def read_file_direct(path : String) : ToolResult
        file_path = Tools.resolve_path(path)

        unless File.exists?(file_path.to_s)
          return ToolResult.error("File not found: #{path}")
        end
        unless File.file?(file_path.to_s)
          return ToolResult.error("Path is not a file: #{path}")
        end

        size = File.size(file_path.to_s)
        if size > MAX_FILE_SIZE
          return ToolResult.error("File too large (max #{MAX_FILE_SIZE} bytes)")
        end

        content = File.read(file_path.to_s)
        ToolResult.success(content)
      end

      private def write_file_direct(path : String, content : String) : ToolResult
        file_path = Tools.resolve_path(path)

        Dir.mkdir_p(File.dirname(file_path.to_s))
        File.write(file_path.to_s, content)

        ToolResult.success("Successfully wrote #{content.bytesize} bytes")
      end

      private def list_dir_direct(path : String) : ToolResult
        dir_path = Tools.resolve_path(path)

        unless Dir.exists?(dir_path.to_s)
          return ToolResult.error("Directory not found: #{path}")
        end

        entries = Dir.entries(dir_path.to_s)
          .reject { |e| e == "." || e == ".." }
          .sort!

        return ToolResult.success("Directory is empty") if entries.empty?

        ToolResult.success(entries.join("\n"))
      end

      private def exec_direct(command : String, timeout : Int32) : ToolResult
        stdout_read, stdout_write = IO.pipe
        stderr_read, stderr_write = IO.pipe

        process = Process.new(
          "sh", ["-c", command],
          output: stdout_write,
          error: stderr_write
        )

        stdout_write.close
        stderr_write.close

        stdout_channel = Channel(String).new(1)
        stderr_channel = Channel(String).new(1)

        spawn { stdout_channel.send(stdout_read.gets_to_end) }
        spawn { stderr_channel.send(stderr_read.gets_to_end) }

        completed = Channel(Process::Status).new(1)
        spawn do
          status = process.wait
          completed.send(status)
        end

        select
        when completed.receive
          # Process completed
        when timeout(timeout.seconds)
          process.signal(Signal::TERM)
          sleep 0.5.seconds
          process.signal(Signal::KILL) unless process.terminated?
          process.wait
        end

        stdout_text = stdout_channel.receive
        stderr_text = stderr_channel.receive

        stdout_read.close
        stderr_read.close

        parts = [] of String
        parts << stdout_text unless stdout_text.empty?
        parts << "STDERR:\n#{stderr_text}" unless stderr_text.empty?

        data = parts.empty? ? "[no output]" : parts.join("\n")
        ToolResult.success(data)
      end
    end
  end
end
