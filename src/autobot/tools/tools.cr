require "json"
require "./base"
require "./registry"
require "./filesystem"
require "./exec"
require "./web"
require "./message"
require "./bash_tool"
require "./sandbox"
require "./sandbox_service"

module Autobot
  module Tools
    # Create a registry populated with all built-in tools.
    #
    # Options:
    #   - `workspace` restricts filesystem tools to a directory
    #   - `exec_timeout` sets shell command timeout (seconds)
    #   - `sandbox_config` sets sandbox mode (auto/bubblewrap/sandboxexec/docker/none)
    #   - `brave_api_key` enables web search
    #   - `skills_dirs` adds extra directories for bash tool discovery
    #   - `use_sandbox_service` enables persistent sandbox service (default: true when sandboxed)
    def self.create_registry(
      workspace : Path? = nil,
      exec_timeout : Int32 = ExecTool::DEFAULT_TIMEOUT,
      exec_deny_patterns : Array(Regex) = ExecTool::DEFAULT_DENY_PATTERNS,
      sandbox_config : String = "auto",
      full_shell_access : Bool = false,
      brave_api_key : String? = nil,
      web_fetch_max_chars : Int32 = WebFetchTool::DEFAULT_MAX_CHARS,
      skills_dirs : Array(String) = [] of String,
      use_sandbox_service : Bool? = nil,
    ) : Registry
      registry = Registry.new

      # Determine sandbox configuration
      sandboxed = sandbox_config.downcase != "none"
      sandbox_type = resolve_sandbox_type(sandbox_config)

      # Log sandbox configuration
      if sandboxed
        log_sandbox_configuration(sandbox_type)
      else
        ::Log.for("Tools").warn { "⚠️  Sandboxing disabled - development mode only" }
      end

      # Create and start sandbox service if enabled
      sandbox_service = create_sandbox_service(
        workspace: workspace,
        sandbox_type: sandbox_type,
        sandboxed: sandboxed,
        use_sandbox_service: use_sandbox_service
      )

      # Log which execution mode is being used
      if sandbox_service
        ::Log.for("Tools").info { "→ Sandbox mode: autobot-server (persistent, ~3ms/op)" }
      elsif sandboxed
        ::Log.for("Tools").info { "→ Sandbox mode: Sandbox.exec (#{sandbox_type.to_s.downcase}, ~50ms/op)" }
      end

      # Register tools
      register_filesystem_tools(registry, sandbox_service, workspace)
      register_exec_tool(registry, sandbox_service, exec_timeout, exec_deny_patterns,
        sandbox_config, full_shell_access, workspace)
      register_web_tools(registry, brave_api_key, web_fetch_max_chars)
      register_bash_tools(registry, skills_dirs, sandbox_service)

      # Store service reference in registry for cleanup
      registry.sandbox_service = sandbox_service if sandbox_service

      registry
    end

    private def self.resolve_sandbox_type(sandbox_config : String) : Sandbox::Type
      case sandbox_config.downcase
      when "bubblewrap"
        Sandbox::Type::Bubblewrap
      when "docker"
        Sandbox::Type::Docker
      when "none"
        Sandbox::Type::None
      else
        Sandbox.detect
      end
    end

    private def self.should_use_server?(sandbox_config : String, use_sandbox_service : Bool?) : Bool
      # Explicit override takes precedence
      return use_sandbox_service unless use_sandbox_service.nil?

      case sandbox_config.downcase
      when "auto"
        command_exists?("autobot-server") # Use if installed
      when "autobot-server"
        true # Explicitly requested
      else
        false # Other modes use Sandbox.exec
      end
    end

    private def self.command_exists?(cmd : String) : Bool
      Process.run("which", [cmd], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    rescue
      false
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

    private def self.create_sandbox_service(
      workspace : Path?,
      sandbox_type : Sandbox::Type,
      sandboxed : Bool,
      use_sandbox_service : Bool?,
    ) : SandboxService?
      return nil unless sandboxed && workspace && sandbox_type != Sandbox::Type::None

      # autobot-server only works with bubblewrap (Linux only)
      # macOS/Windows should use Sandbox.exec + Docker (simpler, works fine)
      return nil unless sandbox_type == Sandbox::Type::Bubblewrap

      # Check if we should use the server
      use_service = use_sandbox_service.nil? ? false : use_sandbox_service
      return nil unless use_service

      # Check if autobot-server binary exists (Linux only)
      unless command_exists?("autobot-server")
        if use_sandbox_service == true
          raise "autobot-server not installed. Install: https://github.com/crystal-autobot/sandbox-server"
        end
        ::Log.for("Tools").debug { "autobot-server not found, using Sandbox.exec" }
        return nil
      end

      begin
        service = SandboxService.new(workspace, sandbox_type)
        service.start
        service
      rescue ex
        ::Log.for("Tools").warn { "autobot-server failed to start: #{ex.message}" }
        ::Log.for("Tools").info { "→ Falling back to Sandbox.exec" }
        nil
      end
    end

    private def self.register_filesystem_tools(
      registry : Registry,
      sandbox_service : SandboxService?,
      workspace : Path?,
    )
      registry.register(ReadFileTool.new(sandbox_service, workspace))
      registry.register(WriteFileTool.new(sandbox_service, workspace))
      registry.register(EditFileTool.new(sandbox_service, workspace))
      registry.register(ListDirTool.new(sandbox_service, workspace))
    end

    private def self.register_exec_tool(
      registry : Registry,
      sandbox_service : SandboxService?,
      timeout : Int32,
      deny_patterns : Array(Regex),
      sandbox_config : String,
      full_shell_access : Bool,
      workspace : Path?,
    )
      registry.register(ExecTool.new(
        timeout: timeout,
        working_dir: workspace.try(&.to_s),
        deny_patterns: deny_patterns,
        sandbox_config: sandbox_config,
        full_shell_access: full_shell_access,
        sandbox_service: sandbox_service,
      ))
    end

    private def self.register_web_tools(
      registry : Registry,
      brave_api_key : String?,
      web_fetch_max_chars : Int32,
    )
      registry.register(WebSearchTool.new(api_key: brave_api_key))
      registry.register(WebFetchTool.new(max_chars: web_fetch_max_chars))
      registry.register(MessageTool.new)
    end

    private def self.register_bash_tools(
      registry : Registry,
      skills_dirs : Array(String),
      sandbox_service : SandboxService?,
    )
      BashToolDiscovery.discover(skills_dirs, sandbox_service).each do |tool|
        registry.register(tool)
      end
    end
  end
end
