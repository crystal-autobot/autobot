require "./result"

module Autobot
  module Tools
    def self.resolve_path(path : String, allowed_dir : Path? = nil) : Path
      resolved = Path[path].expand(home: true)

      if dir = allowed_dir
        canonical_dir = dir.expand(home: true)

        # Resolve real paths to prevent symlink traversal
        resolved_real = resolve_to_real_path(resolved.to_s)
        canonical_real = resolve_to_real_path(canonical_dir.to_s)

        unless path_within_directory?(resolved_real, canonical_real)
          raise PermissionError.new("Access denied")
        end
      end

      resolved
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

      def initialize(@allowed_dir : Path? = nil)
        Log.debug { "ReadFileTool initialized with allowed_dir: #{@allowed_dir.inspect}" }
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
        Log.debug { "Reading file: #{path} (allowed_dir: #{@allowed_dir.inspect})" }

        file_path = Tools.resolve_path(path, @allowed_dir)

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
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied - file '#{path}' is outside workspace")
      rescue ex
        ToolResult.error("Cannot read file: #{ex.message}")
      end
    end

    # Tool to write content to a file.
    class WriteFileTool < Tool
      def initialize(@allowed_dir : Path? = nil)
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
        file_path = Tools.resolve_path(path, @allowed_dir)

        Dir.mkdir_p(File.dirname(file_path.to_s))
        File.write(file_path.to_s, content)

        ToolResult.success("Successfully wrote #{content.bytesize} bytes")
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied - file '#{path}' is outside workspace")
      rescue ex
        ToolResult.error("Cannot write file: #{ex.message}")
      end
    end

    # Tool to edit a file by replacing text.
    class EditFileTool < Tool
      def initialize(@allowed_dir : Path? = nil)
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
        file_path = Tools.resolve_path(path, @allowed_dir)

        unless File.exists?(file_path.to_s)
          return ToolResult.error("File not found: #{path}")
        end

        content = File.read(file_path.to_s)

        unless content.includes?(old_text)
          return ToolResult.error("Text not found in file")
        end

        count = count_occurrences(content, old_text)
        if count > 1
          return ToolResult.error("Text appears #{count} times. Provide more context")
        end

        new_content = content.sub(old_text, new_text)
        File.write(file_path.to_s, new_content)

        ToolResult.success("Successfully edited file")
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied - file '#{path}' is outside workspace")
      rescue ex
        ToolResult.error("Cannot edit file: #{ex.message}")
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
      def initialize(@allowed_dir : Path? = nil)
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
        dir_path = Tools.resolve_path(path, @allowed_dir)

        unless Dir.exists?(dir_path.to_s)
          return ToolResult.error("Directory not found: #{path}")
        end

        entries = Dir.entries(dir_path.to_s)
          .reject { |e| e == "." || e == ".." }
          .sort!

        if entries.empty?
          return ToolResult.success("Directory is empty")
        end

        items = entries.map do |entry|
          full = File.join(dir_path.to_s, entry)
          prefix = Dir.exists?(full) ? "[dir]  " : "[file] "
          "#{prefix}#{entry}"
        end

        ToolResult.success(items.join("\n"))
      rescue ex : PermissionError
        ToolResult.access_denied("Access denied - directory '#{path}' is outside workspace")
      rescue ex
        ToolResult.error("Cannot list directory: #{ex.message}")
      end
    end
  end
end
