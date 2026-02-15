require "./result"
require "./sandbox_executor"
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
    # Uses SandboxExecutor to ensure all operations are sandboxed.
    class ReadFileTool < Tool
      Log = ::Log.for("tools.read_file")

      def initialize(@executor : SandboxExecutor)
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
        @executor.read_file(path)
      end
    end

    # Tool to write content to a file.
    # Uses SandboxExecutor to ensure all operations are sandboxed.
    class WriteFileTool < Tool
      def initialize(@executor : SandboxExecutor)
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
        @executor.write_file(path, content)
      end
    end

    # Tool to edit a file by replacing text.
    # Uses SandboxExecutor to ensure all operations are sandboxed.
    class EditFileTool < Tool
      def initialize(@executor : SandboxExecutor)
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

        read_result = @executor.read_file(path)
        return read_result unless read_result.success?

        content = read_result.content
        result = validate_and_replace(content, old_text, new_text)
        return result unless result.is_a?(String)

        write_result = @executor.write_file(path, result)
        write_result.success? ? ToolResult.success("Successfully edited file") : write_result
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
    # Uses SandboxExecutor to ensure all operations are sandboxed.
    class ListDirTool < Tool
      def initialize(@executor : SandboxExecutor)
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
        @executor.list_dir(path)
      end
    end
  end
end
