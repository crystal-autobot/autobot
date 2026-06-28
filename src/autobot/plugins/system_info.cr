require "./plugin"
require "../tools/result"

module Autobot
  module Plugins
    # Custom plugin to retrieve host system metrics.
    class SystemInfoPlugin < Plugin
      def name : String
        "system_info"
      end

      def description : String
        "Get host system metrics (CPU count, Memory usage, Uptime, Disk space)"
      end

      def version : String
        "0.1.0"
      end

      def setup(context : PluginContext) : Nil
        context.tool_registry.register(SystemInfoTool.new(context.workspace))
      end
    end

    # Custom tool to query system stats.
    class SystemInfoTool < Tools::Tool
      @workspace : Path

      def initialize(@workspace : Path)
      end

      def name : String
        "get_system_info"
      end

      def description : String
        "Returns CPU info, free RAM, uptime, and disk usage for the workspace mount of the host system."
      end

      def parameters : Tools::ToolSchema
        Tools::ToolSchema.new(
          properties: {} of String => Tools::PropertySchema,
          required: [] of String
        )
      end

      def execute(params : Hash(String, JSON::Any)) : Tools::ToolResult
        df_out = run_command("df", ["-h", @workspace.to_s])
        free_out = run_command("free", ["-h"])
        uptime_out = run_command("uptime")

        # For lscpu, retrieve and find the CPU line
        cpu_info = run_command("lscpu")
        cpu_line = if cpu_info.includes?("CPU(s):")
                     cpu_info.lines.find(&.starts_with?("CPU(s):")).try(&.strip) || "Unknown CPU count"
                   else
                     cpu_info
                   end

        content = <<-METRICS
        ### Host Metrics

        **Uptime:**
        #{uptime_out}

        **CPU Info:**
        #{cpu_line}

        **Memory Usage:**
        ```
        #{free_out}
        ```

        **Disk Space (workspace):**
        ```
        #{df_out}
        ```
        METRICS

        Tools::ToolResult.success(content)
      rescue ex
        Tools::ToolResult.error("Failed to retrieve system info: #{ex.message}")
      end

      private def run_command(command : String, args : Array(String) = [] of String) : String
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        status = Process.run(command, args, output: stdout, error: stderr)
        if status.success?
          stdout.to_s.strip
        else
          "Error running #{command}: #{stderr.to_s.strip}"
        end
      rescue ex : File::NotFoundError
        "Command '#{command}' not found"
      rescue ex
        "Error running #{command}: #{ex.message}"
      end
    end
  end
end
