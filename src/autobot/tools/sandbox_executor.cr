require "base64"
require "./result"
require "./sandbox"

module Autobot
  module Tools
    # Centralized sandbox executor - all file and command operations must go through this
    # Prevents tools from bypassing sandboxing by using direct File.* operations
    #
    # Usage:
    #   executor = SandboxExecutor.new(workspace)
    #   result = executor.read_file("test.txt")
    #   result = executor.exec("ls -la")
    class SandboxExecutor
      MAX_FILE_SIZE = 1_048_576

      getter? sandboxed : Bool = true

      def initialize(@workspace : Path?, @sandboxed : Bool = true)
      end

      def read_file(path : String) : ToolResult
        if @sandboxed && (workspace = @workspace)
          read_file_via_sandbox_exec(path, workspace)
        else
          read_file_direct(path)
        end
      rescue ex
        ToolResult.error("Cannot read file: #{ex.message}")
      end

      # Read a file and return base64-encoded contents.
      # Safe for binary files (images, GIFs, documents).
      def read_file_base64(path : String) : ToolResult
        if @sandboxed && (workspace = @workspace)
          success, output = Sandbox.read_file_base64(path, workspace)
          success ? ToolResult.success(output) : ToolResult.error(output)
        else
          read_file_base64_direct(path)
        end
      rescue ex
        ToolResult.error("Cannot read file: #{ex.message}")
      end

      def write_file(path : String, content : String) : ToolResult
        if @sandboxed && (workspace = @workspace)
          write_file_via_sandbox_exec(path, content, workspace)
        else
          write_file_direct(path, content)
        end
      rescue ex
        ToolResult.error("Cannot write file: #{ex.message}")
      end

      def list_dir(path : String) : ToolResult
        if @sandboxed && (workspace = @workspace)
          list_dir_via_sandbox_exec(path, workspace)
        else
          list_dir_direct(path)
        end
      rescue ex
        ToolResult.error("Cannot list directory: #{ex.message}")
      end

      def exec(command : String, timeout : Int32 = 60) : ToolResult
        if @sandboxed && (workspace = @workspace)
          exec_via_sandbox_exec(command, timeout, workspace)
        else
          exec_direct(command, timeout)
        end
      rescue ex
        ToolResult.error("Cannot execute command: #{ex.message}")
      end

      def exec_program(program : String, args : Array(String), timeout : Int32 = 60) : ToolResult
        if @sandboxed && (workspace = @workspace)
          exec_program_via_sandbox_exec(program, args, timeout, workspace)
        else
          exec_program_direct(program, args, timeout)
        end
      rescue ex
        ToolResult.error("Cannot execute program: #{ex.message}")
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
        build_exec_result(status, stdout, stderr)
      end

      private def exec_program_via_sandbox_exec(program : String, args : Array(String), timeout : Int32, workspace : Path) : ToolResult
        status, stdout, stderr = Sandbox.exec_program(program, args, workspace, timeout)
        build_exec_result(status, stdout, stderr)
      end

      # Direct execution (tests and non-sandbox mode)
      private def read_file_base64_direct(path : String) : ToolResult
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

        bytes = File.read(file_path.to_s).to_slice
        ToolResult.success(Base64.strict_encode(bytes))
      end

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
        status, stdout, stderr = Sandbox.capture_command("sh", ["-c", command], timeout)
        build_exec_result(status, stdout, stderr)
      end

      private def build_exec_result(status : Process::Status, stdout : String, stderr : String) : ToolResult
        parts = [] of String
        parts << stdout unless stdout.empty?
        parts << "STDERR:\n#{stderr}" unless stderr.empty?

        if !status.success? && status.exit_code != Sandbox::TIMEOUT_EXIT_CODE
          parts << "\nExit code: #{status.exit_code}"
        end

        data = parts.empty? ? "[no output]" : parts.join("\n")
        ToolResult.success(data)
      end

      private def exec_program_direct(program : String, args : Array(String), timeout : Int32) : ToolResult
        status, stdout, stderr = Sandbox.capture_command(program, args, timeout)
        build_exec_result(status, stdout, stderr)
      end
    end
  end
end
