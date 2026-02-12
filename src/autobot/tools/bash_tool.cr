require "log"
require "../constants"

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

      def initialize(@script_path : String, @tool_name : String? = nil, @tool_description : String? = nil)
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
            "args"  => PropertySchema.new(type: "string", description: "Arguments to pass to the script"),
            "input" => PropertySchema.new(type: "string", description: "Optional stdin input for the script"),
          },
          required: [] of String
        )
      end

      def execute(params : Hash(String, JSON::Any)) : String
        args_str = params["args"]?.try(&.as_s) || ""
        input = params["input"]?.try(&.as_s)

        Log.info { "Running bash tool: #{@script_path} #{args_str}" }

        run_script(args_str, input)
      rescue ex
        "Error running bash tool: #{ex.message}"
      end

      private def run_script(args_str : String, input : String?) : String
        stdout = IO::Memory.new
        stderr = IO::Memory.new

        args = parse_args(args_str)

        process_input = input ? IO::Memory.new(input) : Process::Redirect::Close

        status = Process.run(
          @script_path,
          args: args,
          input: process_input,
          output: stdout,
          error: stderr,
        )

        parts = [] of String
        stdout_text = stdout.to_s
        parts << stdout_text unless stdout_text.empty?

        stderr_text = stderr.to_s
        if !stderr_text.empty? && stderr_text.strip.size > 0
          parts << "STDERR:\n#{stderr_text}"
        end

        unless status.success?
          parts << "Exit code: #{status.exit_code}"
        end

        parts.empty? ? Constants::NO_OUTPUT_MESSAGE : parts.join("\n")
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

    # Discovers bash scripts in skills directories and creates BashTool instances.
    class BashToolDiscovery
      Log = ::Log.for(self)

      SKILLS_DIRS = [
        Path["~/.config/autobot/skills"].expand(home: true).to_s,
        "skills",
      ]

      # Discover all executable .sh files in skills directories.
      # Returns an array of BashTool instances ready for registration.
      def self.discover(extra_dirs : Array(String) = [] of String) : Array(BashTool)
        tools = [] of BashTool
        dirs = SKILLS_DIRS + extra_dirs

        dirs.each do |dir|
          next unless Dir.exists?(dir)

          discover_in_dir(dir, tools)
        end

        Log.info { "Discovered #{tools.size} bash tools" } if tools.size > 0
        tools
      end

      private def self.discover_in_dir(dir : String, tools : Array(BashTool)) : Nil
        Dir.glob(File.join(dir, "**", "*.sh")).each do |script|
          next unless File.info(script).permissions.owner_execute?

          # Read first line for description comment
          desc = extract_description(script)
          tool_name = derive_tool_name(script, dir)

          Log.debug { "Found bash tool: #{tool_name} -> #{script}" }
          tools << BashTool.new(
            script_path: script,
            tool_name: tool_name,
            tool_description: desc
          )
        end
      end

      # Extract description from the first comment line after shebang.
      private def self.extract_description(script_path : String) : String
        File.each_line(script_path) do |line|
          next if line.starts_with?("#!")
          if line.starts_with?("#")
            desc = line.lstrip('#').strip
            return desc unless desc.empty?
          end
          break
        end
        "Run the '#{File.basename(script_path, ".sh")}' bash script."
      end

      # Derive tool name from script path relative to skills dir.
      private def self.derive_tool_name(script_path : String, base_dir : String) : String
        relative = script_path.sub(base_dir, "").lstrip('/')
        name = relative.gsub("/", "_").sub(/\.sh$/, "")
        "bash_#{name}"
      end
    end
  end
end
