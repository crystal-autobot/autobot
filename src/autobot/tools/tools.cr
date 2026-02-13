require "json"
require "./base"
require "./registry"
require "./filesystem"
require "./exec"
require "./web"
require "./message"
require "./bash_tool"

module Autobot
  module Tools
    # Create a registry populated with all built-in tools.
    #
    # Options:
    #   - `workspace` restricts filesystem tools to a directory
    #   - `exec_timeout` sets shell command timeout (seconds)
    #   - `sandbox_config` sets sandbox mode (auto/bubblewrap/docker/none)
    #   - `brave_api_key` enables web search
    #   - `skills_dirs` adds extra directories for bash tool discovery
    def self.create_registry(
      workspace : Path? = nil,
      exec_timeout : Int32 = ExecTool::DEFAULT_TIMEOUT,
      exec_deny_patterns : Array(Regex) = ExecTool::DEFAULT_DENY_PATTERNS,
      sandbox_config : String = "auto",
      full_shell_access : Bool = false,
      brave_api_key : String? = nil,
      web_fetch_max_chars : Int32 = WebFetchTool::DEFAULT_MAX_CHARS,
      skills_dirs : Array(String) = [] of String,
    ) : Registry
      registry = Registry.new

      # Filesystem tools (restrict to workspace if sandboxed)
      sandboxed = sandbox_config.downcase != "none"
      allowed_dir = sandboxed ? workspace : nil
      registry.register(ReadFileTool.new(allowed_dir: allowed_dir))
      registry.register(WriteFileTool.new(allowed_dir: allowed_dir))
      registry.register(EditFileTool.new(allowed_dir: allowed_dir))
      registry.register(ListDirTool.new(allowed_dir: allowed_dir))

      # Shell execution
      registry.register(ExecTool.new(
        timeout: exec_timeout,
        working_dir: workspace.try(&.to_s),
        deny_patterns: exec_deny_patterns,
        sandbox_config: sandbox_config,
        full_shell_access: full_shell_access,
      ))

      # Web tools
      registry.register(WebSearchTool.new(api_key: brave_api_key))
      registry.register(WebFetchTool.new(max_chars: web_fetch_max_chars))

      # Message tool (callback set later when bus is available)
      registry.register(MessageTool.new)

      # Auto-discover bash scripts from skills directories
      BashToolDiscovery.discover(skills_dirs).each do |tool|
        registry.register(tool)
      end

      registry
    end
  end
end
