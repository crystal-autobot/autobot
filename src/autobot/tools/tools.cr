require "json"
require "./base"
require "./registry"
require "./filesystem"
require "./exec"
require "./web"
require "./message"
require "./image_generation"
require "./bash_tool"
require "./sandbox"
require "./sandbox_executor"

module Autobot
  module Tools
    # Create a registry populated with all built-in tools.
    #
    # Options:
    #   - `workspace` restricts filesystem tools to a directory
    #   - `exec_timeout` sets shell command timeout (seconds)
    #   - `sandbox` is the resolved sandbox type (see `Sandbox.configure`)
    #   - `policy` is the capability ceiling every tool is checked against
    #   - `brave_api_key` enables web search
    #   - `skills_dirs` adds extra directories for bash tool discovery
    def self.create_registry(
      workspace : Path? = nil,
      exec_timeout : Int32 = ExecTool::DEFAULT_TIMEOUT,
      exec_deny_patterns : Array(Regex) = ExecTool::DEFAULT_DENY_PATTERNS,
      exec_allow_patterns : Array(Regex) = [] of Regex,
      sandbox : Sandbox::Type = Sandbox::Type::None,
      policy : ToolPolicy = ToolPolicy.gateway,
      brave_api_key : String? = nil,
      web_fetch_max_chars : Int32 = WebFetchTool::DEFAULT_MAX_CHARS,
      skills_dirs : Array(String) = [] of String,
      rate_limiter : RateLimiter? = nil,
      enabled_tools : Array(String) = [] of String,
      filesystem_roots : Array(String) = [] of String,
      web_allowed_domains : Array(String) = [] of String,
    ) : Registry
      registry = Registry.new(rate_limiter: rate_limiter, allowlist: Allowlist.new(enabled_tools), policy: policy)

      log_sandbox_configuration(sandbox)

      executor = SandboxExecutor.new(workspace, sandbox, resolve_roots(filesystem_roots, workspace))

      register_filesystem_tools(registry, executor)
      register_exec_tool(registry, executor, exec_timeout, exec_deny_patterns, exec_allow_patterns, workspace)
      register_web_tools(registry, executor, brave_api_key, web_fetch_max_chars, web_allowed_domains)
      register_bash_tools(registry, executor, skills_dirs)

      # Store reference in registry for plugin access
      registry.sandbox_executor = executor

      ::Log.for("Tools").info { "Registered #{registry.size} tools: #{registry.tool_names.join(", ")}" }

      registry
    end

    # Create a registry for subagent use (no message or spawn tools).
    # Shares the same sandbox config as the parent agent.
    def self.create_subagent_registry(
      workspace : Path,
      exec_timeout : Int32 = ExecTool::DEFAULT_TIMEOUT,
      exec_deny_patterns : Array(Regex) = ExecTool::DEFAULT_DENY_PATTERNS,
      exec_allow_patterns : Array(Regex) = [] of Regex,
      sandbox : Sandbox::Type = Sandbox::Type::None,
      policy : ToolPolicy = ToolPolicy.gateway.background,
      brave_api_key : String? = nil,
      rate_limiter : RateLimiter? = nil,
      enabled_tools : Array(String) = [] of String,
      filesystem_roots : Array(String) = [] of String,
      web_allowed_domains : Array(String) = [] of String,
    ) : Registry
      registry = Registry.new(rate_limiter: rate_limiter, allowlist: Allowlist.new(enabled_tools), policy: policy)
      executor = SandboxExecutor.new(workspace, sandbox, resolve_roots(filesystem_roots, workspace))

      register_filesystem_tools(registry, executor)
      register_exec_tool(registry, executor, exec_timeout, exec_deny_patterns, exec_allow_patterns, workspace)

      registry.register(WebSearchTool.new(api_key: brave_api_key))
      registry.register(WebFetchTool.new(allowed_domains: web_allowed_domains))

      registry.sandbox_executor = executor

      ::Log.for("Tools").info { "Registered #{registry.size} tools: #{registry.tool_names.join(", ")}" }

      registry
    end

    private def self.log_sandbox_configuration(sandbox : Sandbox::Type) : Nil
      log = ::Log.for("Tools")
      sandbox.host? ? log.warn { sandbox.banner } : log.info { sandbox.banner }
    end

    private def self.register_filesystem_tools(
      registry : Registry,
      executor : SandboxExecutor,
    )
      registry.register(ReadFileTool.new(executor))
      registry.register(WriteFileTool.new(executor))
      registry.register(EditFileTool.new(executor))
      registry.register(ListDirTool.new(executor))
    end

    private def self.register_exec_tool(
      registry : Registry,
      executor : SandboxExecutor,
      timeout : Int32,
      deny_patterns : Array(Regex),
      allow_patterns : Array(Regex),
      workspace : Path?,
    )
      registry.register(ExecTool.new(
        executor: executor,
        timeout: timeout,
        working_dir: workspace.try(&.to_s),
        deny_patterns: deny_patterns,
        allow_patterns: allow_patterns,
      ))
    end

    private def self.register_web_tools(
      registry : Registry,
      executor : SandboxExecutor,
      brave_api_key : String?,
      web_fetch_max_chars : Int32,
      web_allowed_domains : Array(String),
    )
      has_search_key = brave_api_key && !brave_api_key.empty?
      if has_search_key
        ::Log.for("Tools").info { "Web search enabled (brave)" }
      else
        ::Log.for("Tools").info { "Web search unavailable (no BRAVE_API_KEY)" }
      end

      registry.register(WebSearchTool.new(api_key: brave_api_key))
      registry.register(WebFetchTool.new(max_chars: web_fetch_max_chars, allowed_domains: web_allowed_domains))
      registry.register(MessageTool.new(executor: executor))
    end

    private def self.register_bash_tools(
      registry : Registry,
      executor : SandboxExecutor,
      skills_dirs : Array(String),
    )
      BashToolDiscovery.discover(executor, skills_dirs).each do |tool|
        registry.register(tool)
      end
    end
  end
end
