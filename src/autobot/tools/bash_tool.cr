require "log"
require "../constants"
require "./result"
require "./sandbox_executor"

module Autobot
  module Tools
    # A tool that wraps a bash script found in a skills directory.
    #
    # Bash tools are auto-discovered from skills/ directories. Each executable
    # `.sh` or `.bash` file becomes a tool the agent can invoke. The script receives
    # arguments as positional parameters and environment variables.
    class BashTool < Tool
      Log = ::Log.for(self)

      SCRIPT_TIMEOUT = 30

      getter script_path : String
      @tool_name : String
      @tool_description : String

      def self.strip_script_extension(filename : String) : String
        if filename.ends_with?(".bash")
          filename.rchop(".bash")
        elsif filename.ends_with?(".sh")
          filename.rchop(".sh")
        else
          filename
        end
      end

      def self.valid_script?(filename : String) : Bool
        !filename.starts_with?(".") && (filename.ends_with?(".sh") || filename.ends_with?(".bash"))
      end

      def self.derive_tool_name(filename : String) : String
        "bash_#{strip_script_extension(filename)}"
      end

      def initialize(@executor : SandboxExecutor, @script_path : String, tool_name : String? = nil, tool_description : String? = nil)
        base = BashTool.strip_script_extension(File.basename(@script_path))
        @tool_name = tool_name || "bash_#{base}"
        @tool_description = tool_description || "Run the '#{base}' bash script."
      end

      def name : String
        @tool_name
      end

      def description : String
        @tool_description
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "args" => PropertySchema.new(type: "string", description: "Arguments to pass to the script"),
          },
          required: [] of String
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        args_str = params["args"]?.try(&.as_s) || ""

        Log.info { "Running bash tool: #{@script_path} #{args_str}" }

        @executor.exec_program(@script_path, parse_args(args_str), timeout: SCRIPT_TIMEOUT)
      rescue ex
        ToolResult.error("Error running bash tool: #{ex.message}")
      end

      private def parse_args(args_str : String) : Array(String)
        return [] of String if args_str.strip.empty?

        args = [] of String
        current_arg = String::Builder.new
        in_quotes = false
        quote_char = '\0'
        escaped = false

        args_str.each_char do |char|
          if escaped
            current_arg << char
            escaped = false
            next
          end

          case char
          when '\\'
            escaped = true
          when '"', '\''
            if in_quotes
              if char == quote_char
                in_quotes = false
                quote_char = '\0'
              else
                current_arg << char
              end
            else
              in_quotes = true
              quote_char = char
            end
          when ' ', '\t'
            if in_quotes
              current_arg << char
            else
              unless current_arg.empty?
                args << current_arg.to_s
                current_arg = String::Builder.new
              end
            end
          else
            current_arg << char
          end
        end

        unless current_arg.empty?
          args << current_arg.to_s
        end

        args
      end
    end

    # Discovers bash scripts in workspace skills directory.
    # Uses direct filesystem access for discovery (read-only, config-controlled paths).
    # Actual script execution at runtime still goes through sandbox.
    class BashToolDiscovery
      Log = ::Log.for(self)

      SKILLS_DIR = "skills"

      def self.discover(executor : SandboxExecutor, extra_dirs : Array(String) = [] of String) : Array(BashTool)
        tools = [] of BashTool
        dirs = [SKILLS_DIR] + extra_dirs

        dirs.each do |dir|
          discover_in_dir(executor, dir, tools)
        end

        Log.info { "Discovered #{tools.size} bash tools" } if tools.size > 0
        tools
      end

      private def self.discover_in_dir(executor : SandboxExecutor, dir : String, tools : Array(BashTool)) : Nil
        return unless Dir.exists?(dir)

        entries = Dir.entries(dir).reject { |entry| entry == "." || entry == ".." }.sort!
        entries.each do |entry|
          next unless valid_script?(entry)

          script_path = "#{dir}/#{entry}"
          next unless File.file?(script_path)

          tool_name = derive_tool_name(entry)
          if tools.any? { |tool| tool.name == tool_name }
            Log.warn { "Duplicate skill tool '#{tool_name}' from #{script_path}, skipping" }
            next
          end

          desc = extract_description(script_path)

          Log.debug { "Found bash tool: #{tool_name} -> #{script_path}" }
          tools << BashTool.new(
            executor: executor,
            script_path: script_path,
            tool_name: tool_name,
            tool_description: desc
          )
        end
      end

      def self.valid_script?(filename : String) : Bool
        BashTool.valid_script?(filename)
      end

      def self.derive_tool_name(filename : String) : String
        BashTool.derive_tool_name(filename)
      end

      private def self.extract_description(script_path : String) : String
        File.each_line(script_path) do |line|
          next if line.starts_with?("#!")
          if line.starts_with?("#")
            desc = line.lstrip('#').strip
            return desc unless desc.empty?
          end
          break
        end
        default_description(script_path)
      rescue
        default_description(script_path)
      end

      private def self.default_description(script_path : String) : String
        "Run the '#{BashTool.strip_script_extension(File.basename(script_path))}' bash script."
      end
    end
  end
end
