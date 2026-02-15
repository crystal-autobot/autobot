require "./result"
require "./sandbox_service"
require "../config/env"

module Autobot
  module Tools
    # Simple path expansion - security handled by kernel sandbox
    def self.resolve_path(path : String) : Path
      # Always block .env files for security
      if Config::Env.file?(path)
        raise PermissionError.new("Access to .env files is always denied for security")
      end

      Path[path].expand(home: true)
    end

    private def self.resolve_to_real_path(path : String) : String
      if File.exists?(path) || Dir.exists?(path)
        File.realpath(path)
      else
        parent = File.dirname(path)
        if File.exists?(parent)
          File.realpath(parent) + "/" + File.basename(path)
        else
          path
        end
      end
    rescue
      path
    end

    private def self.path_within_directory?(path : String, directory : String) : Bool
      path.starts_with?(directory + "/") || path == directory
    end

    class PermissionError < Exception; end

    # Tool to read file contents.
    class ReadFileTool < Tool
      Log = ::Log.for("tools.read_file")

      MAX_FILE_SIZE = 1_048_576 # 1 MB

      def initialize(@sandbox_service : SandboxService?, @workspace : Path? = nil)
      end

      def name : String
        "read_file"
      end

      def description : String
        "Read the contents of a file at the given path."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "path" => PropertySchema.new(type: "string", description: "The file path to read"),
          },
          required: ["path"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        path = params["path"].as_s
        Log.debug { "Reading file: #{path}" }

        if service = @sandbox_service
          read_via_service(service, path)
        elsif workspace = @workspace
          read_via_sandbox_exec(path, workspace)
        else
          read_direct(path)
        end
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied: #{ex.message}")
      rescue ex
        ToolResult.error("Cannot read file: #{ex.message}")
      end

      private def read_via_service(service : SandboxService, path : String) : ToolResult
        operation = SandboxService::Operation.new(
          type: SandboxService::OperationType::ReadFile,
          path: path
        )
        response = service.execute(operation)
        response.success? ? ToolResult.success(response.data || "") : ToolResult.error(response.error || "Unknown error")
      end

      private def read_via_sandbox_exec(path : String, workspace : Path) : ToolResult
        success, output = Sandbox.read_file(path, workspace)
        success ? ToolResult.success(output) : ToolResult.error(output)
      end

      private def read_direct(path : String) : ToolResult
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

        Log.info { "Reading: #{file_path}" }
        content = File.read(file_path.to_s)
        ToolResult.success(content)
      end
    end

    # Tool to write content to a file.
    class WriteFileTool < Tool
      def initialize(@sandbox_service : SandboxService?, @workspace : Path? = nil)
      end

      def name : String
        "write_file"
      end

      def description : String
        "Write content to a file at the given path. Creates parent directories if needed."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "path"    => PropertySchema.new(type: "string", description: "The file path to write to"),
            "content" => PropertySchema.new(type: "string", description: "The content to write"),
          },
          required: ["path", "content"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        path = params["path"].as_s
        content = params["content"].as_s

        if service = @sandbox_service
          write_via_service(service, path, content)
        elsif workspace = @workspace
          write_via_sandbox_exec(path, content, workspace)
        else
          write_direct(path, content)
        end
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied: #{ex.message}")
      rescue ex
        ToolResult.error("Cannot write file: #{ex.message}")
      end

      private def write_via_service(service : SandboxService, path : String, content : String) : ToolResult
        operation = SandboxService::Operation.new(
          type: SandboxService::OperationType::WriteFile,
          path: path,
          content: content
        )
        response = service.execute(operation)
        response.success? ? ToolResult.success(response.data || "") : ToolResult.error(response.error || "Unknown error")
      end

      private def write_via_sandbox_exec(path : String, content : String, workspace : Path) : ToolResult
        success, output = Sandbox.write_file(path, content, workspace)
        success ? ToolResult.success(output) : ToolResult.error(output)
      end

      private def write_direct(path : String, content : String) : ToolResult
        file_path = Tools.resolve_path(path)

        Dir.mkdir_p(File.dirname(file_path.to_s))
        File.write(file_path.to_s, content)

        ToolResult.success("Successfully wrote #{content.bytesize} bytes")
      end
    end

    # Tool to edit a file by replacing text.
    class EditFileTool < Tool
      def initialize(@sandbox_service : SandboxService?, @workspace : Path? = nil)
      end

      def name : String
        "edit_file"
      end

      def description : String
        "Edit a file by replacing old_text with new_text. The old_text must exist exactly in the file."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "path"     => PropertySchema.new(type: "string", description: "The file path to edit"),
            "old_text" => PropertySchema.new(type: "string", description: "The exact text to find and replace"),
            "new_text" => PropertySchema.new(type: "string", description: "The text to replace with"),
          },
          required: ["path", "old_text", "new_text"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        path = params["path"].as_s
        old_text = params["old_text"].as_s
        new_text = params["new_text"].as_s

        if service = @sandbox_service
          edit_via_service(service, path, old_text, new_text)
        elsif workspace = @workspace
          edit_via_sandbox_exec(path, old_text, new_text, workspace)
        else
          edit_direct(path, old_text, new_text)
        end
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied: #{ex.message}")
      rescue ex
        ToolResult.error("Cannot edit file: #{ex.message}")
      end

      private def edit_via_service(service : SandboxService, path : String, old_text : String, new_text : String) : ToolResult
        read_op = SandboxService::Operation.new(
          type: SandboxService::OperationType::ReadFile,
          path: path
        )
        read_response = service.execute(read_op)

        unless read_response.success?
          return ToolResult.error("Cannot read file: #{read_response.error}")
        end

        content = read_response.data || ""
        result = validate_and_replace(content, old_text, new_text)
        return result unless result.is_a?(String)

        write_op = SandboxService::Operation.new(
          type: SandboxService::OperationType::WriteFile,
          path: path,
          content: result
        )
        write_response = service.execute(write_op)

        write_response.success? ? ToolResult.success("Successfully edited file") : ToolResult.error(write_response.error || "Unknown error")
      end

      private def edit_via_sandbox_exec(path : String, old_text : String, new_text : String, workspace : Path) : ToolResult
        success, output = Sandbox.edit_file(path, old_text, new_text, workspace)
        success ? ToolResult.success("Successfully edited file") : ToolResult.error(output)
      end

      private def edit_direct(path : String, old_text : String, new_text : String) : ToolResult
        file_path = Tools.resolve_path(path)

        unless File.exists?(file_path.to_s)
          return ToolResult.error("File not found: #{path}")
        end

        content = File.read(file_path.to_s)
        result = validate_and_replace(content, old_text, new_text)
        return result unless result.is_a?(String)

        File.write(file_path.to_s, result)
        ToolResult.success("Successfully edited file")
      end

      private def validate_and_replace(content : String, old_text : String, new_text : String) : ToolResult | String
        unless content.includes?(old_text)
          return ToolResult.error("Text not found in file")
        end

        count = count_occurrences(content, old_text)
        if count > 1
          return ToolResult.error("Text appears #{count} times. Provide more context")
        end

        content.sub(old_text, new_text)
      end

      private def count_occurrences(haystack : String, needle : String) : Int32
        count = 0
        index = 0
        while pos = haystack.index(needle, index)
          count += 1
          index = pos + needle.size
        end
        count
      end
    end

    # Tool to list directory contents.
    class ListDirTool < Tool
      def initialize(@sandbox_service : SandboxService?, @workspace : Path? = nil)
      end

      def name : String
        "list_dir"
      end

      def description : String
        "List the contents of a directory."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "path" => PropertySchema.new(type: "string", description: "The directory path to list"),
          },
          required: ["path"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        path = params["path"].as_s

        if service = @sandbox_service
          list_via_service(service, path)
        elsif workspace = @workspace
          list_via_sandbox_exec(path, workspace)
        else
          list_direct(path)
        end
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied: #{ex.message}")
      rescue ex
        ToolResult.error("Cannot list directory: #{ex.message}")
      end

      private def list_via_service(service : SandboxService, path : String) : ToolResult
        operation = SandboxService::Operation.new(
          type: SandboxService::OperationType::ListDir,
          path: path
        )
        response = service.execute(operation)
        response.success? ? ToolResult.success(response.data || "") : ToolResult.error(response.error || "Unknown error")
      end

      private def list_via_sandbox_exec(path : String, workspace : Path) : ToolResult
        success, output = Sandbox.list_dir(path, workspace)
        return ToolResult.error(output) unless success

        entries = output.split("\n").reject(&.empty?).reject { |e| e == "." || e == ".." }.sort!
        return ToolResult.success("Directory is empty") if entries.empty?

        ToolResult.success(entries.join("\n"))
      end

      private def list_direct(path : String) : ToolResult
        dir_path = Tools.resolve_path(path)

        unless Dir.exists?(dir_path.to_s)
          return ToolResult.error("Directory not found: #{path}")
        end

        entries = Dir.entries(dir_path.to_s)
          .reject { |e| e == "." || e == ".." }
          .reject { |e| Config::Env.file?(e) } # Hide .env files
          .sort!

        return ToolResult.success("Directory is empty") if entries.empty?

        items = entries.map do |entry|
          full = File.join(dir_path.to_s, entry)
          prefix = Dir.exists?(full) ? "[dir]  " : "[file] "
          "#{prefix}#{entry}"
        end

        ToolResult.success(items.join("\n"))
      end
    end
  end
end
