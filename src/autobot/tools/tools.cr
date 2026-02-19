require "json"
require "./base"
require "./registry"
require "./filesystem"
require "./exec"
require "./web"
require "./message"
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
    #   - `sandbox_config` sets sandbox mode (auto/bubblewrap/docker/none)
    #   - `brave_api_key` enables web search
    #   - `skills_dirs` adds extra directories for bash tool discovery
    def self.create_registry(
      workspace : Path? = nil,
      exec_timeout : Int32 = ExecTool::DEFAULT_TIMEOUT,
      exec_deny_patterns : Array(Regex) = ExecTool::DEFAULT_DENY_PATTERNS,
      sandbox_config : String = "auto",
      brave_api_key : String? = nil,
      web_fetch_max_chars : Int32 = WebFetchTool::DEFAULT_MAX_CHARS,
      skills_dirs : Array(String) = [] of String,
    ) : Registry
      registry = Registry.new

      # Determine sandbox configuration
      sandboxed = sandbox_config.downcase != "none"
      sandbox_type = Sandbox.resolve_type(sandbox_config)

      # Log sandbox configuration
      if sandboxed
        log_sandbox_configuration(sandbox_type)
      else
        ::Log.for("Tools").warn { "⚠️  Sandboxing disabled - development mode only" }
      end

      # Create centralized sandbox executor
      executor = SandboxExecutor.new(workspace)

      # Register tools
      register_filesystem_tools(registry, executor)
      register_exec_tool(registry, executor, exec_timeout, exec_deny_patterns,
        sandbox_config, workspace)
      register_web_tools(registry, brave_api_key, web_fetch_max_chars)
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
      sandbox_config : String = "auto",
      brave_api_key : String? = nil,
    ) : Registry
      registry = Registry.new

      executor = SandboxExecutor.new(workspace)

      register_filesystem_tools(registry, executor)
      register_exec_tool(registry, executor, exec_timeout, ExecTool::DEFAULT_DENY_PATTERNS,
        sandbox_config, workspace)

      registry.register(WebSearchTool.new(api_key: brave_api_key))
      registry.register(WebFetchTool.new)

      registry.sandbox_executor = executor

      ::Log.for("Tools").info { "Registered #{registry.size} tools: #{registry.tool_names.join(", ")}" }

      registry
    end

    private def self.log_sandbox_configuration(sandbox_type : Sandbox::Type) : Nil
      case sandbox_type
      when Sandbox::Type::Bubblewrap
        ::Log.for("Tools").info { "✓ Sandbox: bubblewrap (Linux namespaces)" }
      when Sandbox::Type::Docker
        ::Log.for("Tools").info { "✓ Sandbox: Docker (container isolation)" }
      when Sandbox::Type::None
        ::Log.for("Tools").warn { "⚠️  No sandbox tool found - install bubblewrap or Docker" }
      end
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
      sandbox_config : String,
      workspace : Path?,
    )
      registry.register(ExecTool.new(
        executor: executor,
        timeout: timeout,
        working_dir: workspace.try(&.to_s),
        deny_patterns: deny_patterns,
        sandbox_config: sandbox_config,
      ))
    end

    private def self.register_web_tools(
      registry : Registry,
      brave_api_key : String?,
      web_fetch_max_chars : Int32,
    )
      has_search_key = brave_api_key && !brave_api_key.empty?
      if has_search_key
        ::Log.for("Tools").info { "Web search enabled (brave)" }
      else
        ::Log.for("Tools").info { "Web search unavailable (no BRAVE_API_KEY)" }
      end

      registry.register(WebSearchTool.new(api_key: brave_api_key))
      registry.register(WebFetchTool.new(max_chars: web_fetch_max_chars))
      registry.register(MessageTool.new)
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
