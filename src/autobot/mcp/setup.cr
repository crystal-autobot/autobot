require "./client"
require "./proxy_tool"

module Autobot
  # MCP (Model Context Protocol) client integration.
  #
  # Connects to external MCP servers (e.g. Garmin, GitHub) defined in config,
  # discovers their tools, and registers them as regular autobot tools so
  # the LLM can use them transparently.
  #
  # MCP servers run as child processes communicating over stdio (JSON-RPC 2.0).
  # They are NOT sandboxed (they need network access for external APIs),
  # but env vars are isolated and responses are truncated.
  module Mcp
    Log = ::Log.for("mcp")

    # Starts MCP server processes in the background without blocking startup.
    # Returns the clients array immediately; servers connect and register
    # their tools asynchronously as they become ready.
    # No-op when no MCP config exists.
    def self.setup(config : Config::Config, tool_registry : Tools::Registry) : Array(Client)
      clients = [] of Client

      mcp_config = config.mcp
      return clients unless mcp_config

      servers = mcp_config.servers
      return clients if servers.empty?

      Log.info { "Starting #{servers.size} MCP server(s) in background" }

      spawn(name: "mcp-setup") do
        start_all(servers, clients, tool_registry)
      end

      clients
    end

    # Starts all servers concurrently in the background,
    # discovers tools, and registers them as they connect.
    private def self.start_all(
      servers : Hash(String, Config::McpServerConfig),
      clients : Array(Client),
      tool_registry : Tools::Registry,
    ) : Nil
      channel = Channel({Client, Config::McpServerConfig} | Nil).new

      servers.each do |server_name, server_config|
        spawn do
          client = start_server(server_name, server_config)
          channel.send(client ? {client, server_config} : nil)
        end
      end

      servers.size.times do
        result = channel.receive
        next unless result

        client, server_config = result
        clients << client
        register_tools(client, tool_registry, server_config.tools)
      end

      Log.info { "MCP setup complete: #{clients.size}/#{servers.size} server(s) connected" }
    rescue ex
      Log.error { "MCP background setup failed: #{ex.message}" }
    end

    # Gracefully stop all MCP client processes.
    def self.stop_all(clients : Array(Client)) : Nil
      clients.each do |client|
        client.stop
      rescue ex
        Log.warn { "Error stopping MCP server '#{client.server_name}': #{ex.message}" }
      end
    end

    private def self.start_server(name : String, config : Config::McpServerConfig) : Client?
      if config.command.empty?
        Log.warn { "[#{name}] MCP server has no command configured, skipping" }
        return nil
      end

      client = Client.new(
        server_name: name,
        command: config.command,
        args: config.args,
        env: config.env,
      )

      client.start
      client
    rescue ex
      Log.error { "[#{name}] Failed to start MCP server: #{ex.message}" }
      nil
    end

    private def self.register_tools(client : Client, registry : Tools::Registry, allowlist : Array(String)) : Nil
      tools = client.list_tools
      registered = 0

      tools.each do |tool_json|
        remote_name = tool_json["name"]?.try(&.as_s?) || "unknown"
        next unless tool_allowed?(remote_name, allowlist)

        proxy = ProxyTool.from_mcp_tool(client, tool_json)
        registry.register(proxy)
        registered += 1
        Log.info { "Registered MCP tool: #{proxy.name}" }
      end

      if allowlist.empty?
        Log.info { "[#{client.server_name}] #{registered} tools registered" }
      else
        Log.info { "[#{client.server_name}] #{registered}/#{tools.size} tools registered (filtered)" }
      end
    rescue ex
      Log.error { "[#{client.server_name}] Failed to discover tools: #{ex.message}" }
    end

    # Checks if a tool name matches the allowlist.
    # Empty allowlist means all tools are allowed.
    # Patterns ending with `*` match as prefixes.
    def self.tool_allowed?(name : String, allowlist : Array(String)) : Bool
      return true if allowlist.empty?

      allowlist.any? do |pattern|
        if pattern.ends_with?("*")
          name.starts_with?(pattern.rchop("*"))
        else
          name == pattern
        end
      end
    end
  end
end
