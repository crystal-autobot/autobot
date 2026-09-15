require "log"
require "../constants"
require "./result"
require "./sandbox_executor"
require "../agent/skills"

module Autobot
  module Tools
    # A tool that wraps a bash script found in a skills directory.
    #
    # Bash tools are auto-discovered from skills/ directories. Each executable
    # `.sh` file becomes a tool the agent can invoke. The script receives
    # arguments as positional parameters and environment variables: the
    # parameters its SKILL.md declares, in order, or the split `args` string.
    class BashTool < Tool
      Log = ::Log.for(self)

      SCRIPT_TIMEOUT = 30

      getter script_path : String
      getter params : Array(Agent::SkillParam)
      @tool_name : String
      @tool_description : String

      def initialize(
        @executor : SandboxExecutor,
        @script_path : String,
        @tool_name : String? = nil,
        @tool_description : String? = nil,
        @params = [] of Agent::SkillParam,
      )
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
        return args_schema if @params.empty?

        properties = {} of String => PropertySchema
        @params.each { |param| properties[param.name] = PropertySchema.new(type: "string", description: param.description) }
        ToolSchema.new(properties: properties, required: @params.map(&.name))
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        argv = @params.empty? ? parse_args(params["args"]?.try(&.as_s) || "") : declared_args(params)

        Log.info { "Running bash tool: #{@script_path} #{argv.join(" ")}" }

        @executor.exec_program(@script_path, argv, timeout: SCRIPT_TIMEOUT)
      rescue ex
        ToolResult.error("Error running bash tool: #{ex.message}")
      end

      private def args_schema : ToolSchema
        ToolSchema.new(
          properties: {
            "args" => PropertySchema.new(type: "string", description: "Arguments to pass to the script"),
          },
          required: [] of String
        )
      end

      private def declared_args(params : Hash(String, JSON::Any)) : Array(String)
        @params.map { |param| params[param.name]?.try(&.as_s?) || "" }
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

        entries = Dir.entries(dir).reject { |e| e == "." || e == ".." }.sort!
        entries.each do |entry|
          next unless entry.ends_with?(".sh")

          script_path = "#{dir}/#{entry}"
          desc = extract_description(script_path)
          tool_name = derive_tool_name(entry)

          Log.debug { "Found bash tool: #{tool_name} -> #{script_path}" }
          tools << BashTool.new(
            executor: executor,
            script_path: script_path,
            tool_name: tool_name,
            tool_description: desc,
            params: declared_params(dir, entry)
          )
        end
      end

      def self.declared_params(dir : String, entry : String) : Array(Agent::SkillParam)
        skill_file = "#{dir}/#{File.basename(entry, ".sh")}/SKILL.md"
        return [] of Agent::SkillParam unless File.exists?(skill_file)

        Agent::SkillsLoader.parse_frontmatter(File.read(skill_file)).params
      rescue
        [] of Agent::SkillParam
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
        "Run the '#{File.basename(script_path, ".sh")}' bash script."
      end

      private def self.derive_tool_name(filename : String) : String
        name = filename.sub(/\.sh$/, "")
        "bash_#{name}"
      end
    end
  end
end
