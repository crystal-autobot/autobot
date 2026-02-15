require "log"
require "../constants"
require "./result"
require "./sandbox_service"

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
      @sandbox_service : SandboxService?

      def initialize(@script_path : String, @tool_name : String? = nil, @tool_description : String? = nil, @sandbox_service : SandboxService? = nil)
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

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        args_str = params["args"]?.try(&.as_s) || ""
        input = params["input"]?.try(&.as_s)

        Log.info { "Running bash tool: #{@script_path} #{args_str}" }

        result = run_script(args_str, input)
        ToolResult.success(result)
      rescue ex
        ToolResult.error("Error running bash tool: #{ex.message}")
      end

      private def run_script(args_str : String, input : String?) : String
        # Build command to execute
        args = parse_args(args_str)
        command = "#{@script_path} #{args.map { |arg| shell_escape(arg) }.join(" ")}"

        # Use sandbox service if available
        if service = @sandbox_service
          operation = SandboxService::Operation.new(
            type: SandboxService::OperationType::Exec,
            command: command,
            stdin: input,
            timeout: SCRIPT_TIMEOUT
          )
          response = service.execute(operation)

          if response.success?
            response.data || ""
          else
            raise "Sandbox execution failed: #{response.error}"
          end
        else
          # Fallback to direct execution (for tests/development)
          # Use pipes with size limits to prevent DoS
          stdout_read, stdout_write = IO.pipe
          stderr_read, stderr_write = IO.pipe

          process_input = input ? IO::Memory.new(input) : Process::Redirect::Close

          process = Process.new(
            @script_path,
            args: args,
            input: process_input,
            output: stdout_write,
            error: stderr_write,
          )

          stdout_write.close
          stderr_write.close

          # Read with size limits
          stdout_channel = Channel(String).new(1)
          stderr_channel = Channel(String).new(1)
          spawn { stdout_channel.send(read_limited(stdout_read)) }
          spawn { stderr_channel.send(read_limited(stderr_read)) }

          # Enforce timeout
          completed = Channel(Process::Status).new(1)
          spawn do
            status = process.wait
            completed.send(status)
          end

          timed_out, status = wait_for_timeout(process, completed)

          stdout_text = stdout_channel.receive
          stderr_text = stderr_channel.receive
          stdout_read.close
          stderr_read.close

          build_script_result(stdout_text, stderr_text, status, timed_out)
        end
      end

      private def shell_escape(arg : String) : String
        if arg.includes?(' ') || arg.includes?('\t') || arg.includes?('"') || arg.includes?('\'')
          "'#{arg.gsub("'", "'\\''")}'"
        else
          arg
        end
      end

      private def read_limited(io : IO, max_size : Int32 = 10_000) : String
        buffer = IO::Memory.new
        bytes_read = 0
        chunk = Bytes.new(4096)

        while (n = io.read(chunk)) > 0
          bytes_read += n
          if bytes_read > max_size
            buffer.write(chunk[0, Math.max(0, max_size - (bytes_read - n))])
            buffer << "\n... (output truncated at #{max_size} bytes)"
            break
          end
          buffer.write(chunk[0, n])
        end

        buffer.to_s
      rescue
        ""
      end

      private def wait_for_timeout(process : Process, completed : Channel(Process::Status)) : {Bool, Process::Status?}
        select
        when status = completed.receive
          {false, status}
        when timeout(SCRIPT_TIMEOUT.seconds)
          begin
            process.signal(Signal::TERM)
            sleep 0.5.seconds
            process.signal(Signal::KILL) unless process.terminated?
            process.wait
          rescue
          end
          {true, nil}
        end
      end

      private def build_script_result(stdout : String, stderr : String, status : Process::Status?, timed_out : Bool) : String
        parts = [] of String

        if timed_out
          parts << "Error: Script timed out after #{SCRIPT_TIMEOUT} seconds"
        end

        parts << stdout unless stdout.empty?

        if !stderr.empty? && stderr.strip.size > 0
          parts << "STDERR:\n#{stderr}"
        end

        if status && !status.success? && !timed_out
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
      def self.discover(extra_dirs : Array(String) = [] of String, sandbox_service : SandboxService? = nil) : Array(BashTool)
        tools = [] of BashTool
        dirs = SKILLS_DIRS + extra_dirs

        dirs.each do |dir|
          next unless Dir.exists?(dir)

          discover_in_dir(dir, tools, sandbox_service)
        end

        Log.info { "Discovered #{tools.size} bash tools" } if tools.size > 0
        tools
      end

      private def self.discover_in_dir(dir : String, tools : Array(BashTool), sandbox_service : SandboxService?) : Nil
        Dir.glob(File.join(dir, "**", "*.sh")).each do |script|
          next unless File.info(script).permissions.owner_execute?

          # Read first line for description comment
          desc = extract_description(script)
          tool_name = derive_tool_name(script, dir)

          Log.debug { "Found bash tool: #{tool_name} -> #{script}" }
          tools << BashTool.new(
            script_path: script,
            tool_name: tool_name,
            tool_description: desc,
            sandbox_service: sandbox_service
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
