require "log"
require "../constants"
require "./result"
require "./sandbox_executor"

module Autobot
  module Tools
    # A tool that wraps a bash script found in a skills directory.
    #
    # Bash tools are auto-discovered from skills/ directories. Each executable
    # `.sh` file becomes a tool the agent can invoke. The script receives
    # arguments as positional parameters and environment variables.
    class BashTool < Tool
      Log = ::Log.for(self)

      SCRIPT_TIMEOUT = 30

      getter script_path : String
      @tool_name : String
      @tool_description : String

      def initialize(@executor : SandboxExecutor, @script_path : String, @tool_name : String? = nil, @tool_description : String? = nil)
        base = File.basename(@script_path, ".sh")
        @tool_name ||= "bash_#{base}"
        @tool_description ||= "Run the '#{base}' bash script."
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

        result = run_script(args_str)
        ToolResult.success(result)
      rescue ex
        ToolResult.error("Error running bash tool: #{ex.message}")
      end

      private def run_script(args_str : String) : String
        args = parse_args(args_str)
        command = "#{@script_path} #{args.map { |arg| shell_escape(arg) }.join(" ")}"

        result = @executor.exec(command, timeout: SCRIPT_TIMEOUT)

        if result.success?
          result.content
        else
          raise "Script execution failed: #{result.content}"
        end
      end

      private def shell_escape(arg : String) : String
        "'#{arg.gsub("'", "'\\''")}'"
      end

      private def parse_args(args_str : String) : Array(String)
        return [] of String if args_str.strip.empty?

        args = [] of String
        current_arg = ""
        in_quotes = false
        quote_char = '\0'
        escaped = false

        args_str.each_char do |char|
          if escaped
            current_arg += char.to_s
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
                current_arg += char.to_s
              end
            else
              in_quotes = true
              quote_char = char
            end
          when ' ', '\t'
            if in_quotes
              current_arg += char.to_s
            else
              unless current_arg.empty?
                args << current_arg
                current_arg = ""
              end
            end
          else
            current_arg += char.to_s
          end
        end

        unless current_arg.empty?
          args << current_arg
        end

        args
      end
    end

    # Discovers bash scripts in workspace skills directory
    # Only searches within workspace for security
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
        list_result = executor.list_dir(dir)
        return unless list_result.success?

        list_result.content.split("\n").each do |entry|
          next unless entry.ends_with?(".sh")

          script_path = "#{dir}/#{entry}"
          desc = extract_description(executor, script_path)
          tool_name = derive_tool_name(entry)

          Log.debug { "Found bash tool: #{tool_name} -> #{script_path}" }
          tools << BashTool.new(
            executor: executor,
            script_path: script_path,
            tool_name: tool_name,
            tool_description: desc
          )
        end
      end

      private def self.extract_description(executor : SandboxExecutor, script_path : String) : String
        result = executor.read_file(script_path)
        return default_description(script_path) unless result.success?

        result.content.each_line do |line|
          next if line.starts_with?("#!")
          if line.starts_with?("#")
            desc = line.lstrip('#').strip
            return desc unless desc.empty?
          end
          break
        end

        default_description(script_path)
      end

      private def self.default_description(script_path : String) : String
        "Run the '#{File.basename(script_path, ".sh")}' bash script."
      end

      private def self.derive_tool_name(filename : String) : String
        name = filename.sub(/\.sh$/, "")
        "bash_#{name}"
      end
    end
  end
end
