require "base64"
require "../config/env"
require "./command_runner"
require "./result"
require "./paths"
require "./sandbox"

module Autobot
  module Tools
    # Centralized sandbox executor - all file and command operations must go through this
    # Prevents tools from bypassing sandboxing by using direct File.* operations
    #
    # Usage:
    #   executor = SandboxExecutor.new(workspace, Sandbox::Type::Bubblewrap)
    #   result = executor.read_file("test.txt")
    #   result = executor.exec("ls -la")
    class SandboxExecutor
      MAX_FILE_SIZE = 1_048_576
      SKILLS_DIR    = "skills"

      getter mode : Sandbox::Type
      getter roots : Array(Path)

      @base : Path
      @real_base : Path
      @real_skills : Path
      @real_roots : Array(Path)

      def initialize(@workspace : Path?, @mode : Sandbox::Type = Sandbox.type, @roots : Array(Path) = [] of Path)
        @base = @workspace || Path[Dir.current]
        @real_base = Tools.realpath(@base)
        @real_skills = Tools.realpath(@base / SKILLS_DIR)
        @real_roots = @roots.map { |root| Tools.realpath(root) }
      end

      def sandboxed? : Bool
        !@mode.host?
      end

      def host_exec? : Bool
        @mode.host_exec?
      end

      def read_file(path : String) : ToolResult
        target = confine(path, reading: true)
        return target if target.is_a?(ToolResult)

        if workspace = sandbox_workspace
          read_file_via_sandbox_exec(target, workspace)
        else
          read_file_direct(target, path)
        end
      rescue ex
        ToolResult.error("Cannot read file: #{ex.message}")
      end

      # Read a file and return base64-encoded contents.
      # Safe for binary files (images, GIFs, documents).
      def read_file_base64(path : String) : ToolResult
        target = confine(path, reading: true)
        return target if target.is_a?(ToolResult)

        if workspace = sandbox_workspace
          success, output = Sandbox.read_file_base64(target.to_s, workspace)
          success ? ToolResult.success(output) : ToolResult.error(output)
        else
          read_file_base64_direct(target, path)
        end
      rescue ex
        ToolResult.error("Cannot read file: #{ex.message}")
      end

      def write_file(path : String, content : String) : ToolResult
        target = confine(path, reading: false)
        return target if target.is_a?(ToolResult)

        if workspace = sandbox_workspace
          write_file_via_sandbox_exec(target, content, workspace)
        else
          write_file_direct(target, content)
        end
      rescue ex
        ToolResult.error("Cannot write file: #{ex.message}")
      end

      def list_dir(path : String) : ToolResult
        target = confine(path, reading: true)
        return target if target.is_a?(ToolResult)

        if workspace = sandbox_workspace
          list_dir_via_sandbox_exec(target, workspace)
        else
          list_dir_direct(target, path)
        end
      rescue ex
        ToolResult.error("Cannot list directory: #{ex.message}")
      end

      def exec(command : String, timeout : Int32 = 60, cwd : String? = nil) : ToolResult
        relative = cwd ? relative_cwd(cwd) : ""
        return ToolResult.access_denied("Working directory is outside the workspace: #{cwd}") unless relative

        if workspace = sandbox_workspace
          command = "cd #{Sandbox.shell_escape(relative)} && #{command}" unless relative.empty?
          ToolResult.success(format_exec_output(Sandbox.exec(command, workspace, timeout)))
        else
          ToolResult.success(format_exec_output(CommandRunner.run("sh", ["-c", command], timeout, chdir: cwd)))
        end
      rescue ex
        ToolResult.error("Cannot execute command: #{ex.message}")
      end

      def exec_program(program : String, args : Array(String), timeout : Int32 = 60) : ToolResult
        result = if workspace = sandbox_workspace
                   Sandbox.exec_program(program, args, workspace, timeout)
                 else
                   CommandRunner.run(program, args, timeout)
                 end
        output = format_exec_output(result)
        result.success? ? ToolResult.success(output) : ToolResult.error(output)
      rescue ex
        ToolResult.error("Cannot execute program: #{ex.message}")
      end

      private def sandbox_workspace : Path?
        @workspace if sandboxed?
      end

      private def confine(path : String, reading : Bool) : Path | ToolResult
        resolved = Tools.realpath(Path[path].expand(base: @base, home: true))
        return ToolResult.access_denied("Access to .env files is not allowed: #{path}") if Config::Env.file?(resolved)
        return resolved if unconfined? || allowed?(resolved, reading)

        outside(path)
      end

      private def unconfined? : Bool
        @workspace.nil? && @real_roots.empty?
      end

      private def allowed?(resolved : Path, reading : Bool) : Bool
        return true if reading && Tools.inside?(resolved, @real_skills)

        allowed = @real_roots.empty? ? [@real_base] : @real_roots
        allowed.any? { |root| Tools.inside?(resolved, root) }
      end

      private def outside(path : String) : ToolResult
        return ToolResult.access_denied("Path is outside the workspace: #{path}") if @roots.empty?

        names = @roots.map(&.relative_to(@base).to_s)
        ToolResult.access_denied("Path is outside the allowed directories (#{names.join(", ")}): #{path}")
      end

      private def relative_cwd(cwd : String) : String?
        return "" unless @workspace

        real = Path[File.realpath(Path[cwd].expand(base: @base, home: true).to_s)]
        return nil unless Tools.inside?(real, @real_base)

        real == @real_base ? "" : real.relative_to(@real_base).to_s
      rescue File::Error
        nil
      end

      private def read_file_via_sandbox_exec(path : Path, workspace : Path) : ToolResult
        success, output = Sandbox.read_file(path.to_s, workspace)
        success ? ToolResult.success(output) : ToolResult.error(output)
      end

      private def write_file_via_sandbox_exec(path : Path, content : String, workspace : Path) : ToolResult
        success, output = Sandbox.write_file(path.to_s, content, workspace)
        success ? ToolResult.success(output) : ToolResult.error(output)
      end

      private def list_dir_via_sandbox_exec(path : Path, workspace : Path) : ToolResult
        success, output = Sandbox.list_dir(path.to_s, workspace)
        return ToolResult.error(output) unless success

        list_result(output.split("\n"))
      end

      private def list_result(entries : Array(String)) : ToolResult
        visible = entries.reject { |entry| entry.empty? || entry == "." || entry == ".." || Config::Env.file?(entry) }.sort!
        return ToolResult.success("Directory is empty") if visible.empty?

        ToolResult.success(visible.join("\n"))
      end

      private def read_file_base64_direct(file_path : Path, path : String) : ToolResult
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

      private def read_file_direct(file_path : Path, path : String) : ToolResult
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

      private def write_file_direct(file_path : Path, content : String) : ToolResult
        Dir.mkdir_p(File.dirname(file_path.to_s))
        File.write(file_path.to_s, content)

        ToolResult.success("Successfully wrote #{content.bytesize} bytes")
      end

      private def list_dir_direct(dir_path : Path, path : String) : ToolResult
        unless Dir.exists?(dir_path.to_s)
          return ToolResult.error("Directory not found: #{path}")
        end

        list_result(Dir.entries(dir_path.to_s))
      end

      private def format_exec_output(result : CommandRunner::Result) : String
        result.report.presence || "[no output]"
      end
    end
  end
end
