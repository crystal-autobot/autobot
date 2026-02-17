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

    # Spawns MCP server processes defined in config, discovers tools,
    # and registers them in the tool registry.
    # Returns the list of active clients for lifecycle management.
    # No-op when no MCP config exists.
    def self.setup(config : Config::Config, tool_registry : Tools::Registry) : Array(Client)
      clients = [] of Client

      mcp_config = config.mcp
      return clients unless mcp_config

      servers = mcp_config.servers
      return clients if servers.empty?

      servers.each do |server_name, server_config|
        client = start_server(server_name, server_config)
        next unless client

        clients << client
        register_tools(client, tool_registry)
      end

      clients
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

    private def self.register_tools(client : Client, registry : Tools::Registry) : Nil
      tools = client.list_tools

      tools.each do |tool_json|
        proxy = ProxyTool.from_mcp_tool(client, tool_json)
        registry.register(proxy)
        Log.info { "Registered MCP tool: #{proxy.name}" }
      end

      Log.info { "[#{client.server_name}] #{tools.size} tools discovered" }
    rescue ex
      Log.error { "[#{client.server_name}] Failed to discover tools: #{ex.message}" }
    end
  end
end
