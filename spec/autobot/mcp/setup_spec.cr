require "../../spec_helper"

# A minimal shell script that speaks MCP protocol over stdio.
# Responds to initialize (id=1) and tools/list (id=2), then stays alive.
MCP_MOCK_SCRIPT = <<-BASH
  #!/bin/bash
  read line
  echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{}}}'
  read line
  read line
  echo '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"mock_tool","description":"A mock tool","inputSchema":{"type":"object","properties":{"q":{"type":"string"}}}}]}}'
  while read line; do :; done
  BASH

private def create_mock_server_script : String
  path = File.tempname("mcp_mock", ".sh")
  File.write(path, MCP_MOCK_SCRIPT)
  File.chmod(path, 0o755)
  path
end

# In-process mock that implements the Client interface without spawning a subprocess.
# Used for fast unit tests that don't need real process lifecycle.
class MockMcpClient < Autobot::Mcp::Client
  MOCK_TOOLS_JSON = <<-JSON
    {"name":"mock_tool","description":"A mock tool","inputSchema":{"type":"object","properties":{"q":{"type":"string"}}}}
  JSON

  getter? stopped : Bool = false

  def initialize(server_name : String)
    super(
      server_name: server_name,
      command: "mock",
      args: [] of String,
      env: {} of String => String,
    )
  end

  def start : Nil
  end

  def stop : Nil
    @stopped = true
  end

  def alive? : Bool
    !@stopped
  end

  def list_tools : Array(JSON::Any)
    [JSON.parse(MOCK_TOOLS_JSON)]
  end
end

private def mock_client_factory : Autobot::Mcp::ClientFactory
  Proc(String, Autobot::Config::McpServerConfig, Autobot::Mcp::Client?).new do |name, _config|
    MockMcpClient.new(name)
  end
end

describe Autobot::Mcp do
  describe ".setup" do
    it "returns empty array when no MCP config" do
      config = Autobot::Config::Config.from_yaml("--- {}")
      registry = Autobot::Tools::Registry.new

      clients = Autobot::Mcp.setup(config, registry)

      clients.should be_empty
      registry.size.should eq(0)
    end

    it "returns empty array when servers hash is empty" do
      config = Autobot::Config::Config.from_yaml(<<-YAML
      mcp:
        servers: {}
      YAML
      )
      registry = Autobot::Tools::Registry.new

      clients = Autobot::Mcp.setup(config, registry)

      clients.should be_empty
    end

    it "returns immediately without blocking" do
      script = create_mock_server_script
      config = Autobot::Config::Config.from_yaml(<<-YAML
      mcp:
        servers:
          test:
            command: "bash"
            args: ["#{script}"]
      YAML
      )
      registry = Autobot::Tools::Registry.new

      clients = Autobot::Mcp.setup(config, registry)

      # Should return immediately with empty array
      # (servers connect in background)
      clients.should be_empty
      registry.size.should eq(0)
    ensure
      clients.try { |list| Autobot::Mcp.stop_all(list) }
      File.delete(script) if script && File.exists?(script)
    end

    it "registers tools in the background after setup returns" do
      config = Autobot::Config::Config.from_yaml(<<-YAML
      mcp:
        servers:
          test:
            command: "mock"
      YAML
      )
      registry = Autobot::Tools::Registry.new

      clients = Autobot::Mcp.setup(config, registry, mock_client_factory)

      sleep 0.1.seconds

      clients.size.should eq(1)
      clients.first.server_name.should eq("test")
      clients.first.alive?.should be_true
      registry.has?("mcp_test_mock_tool").should be_true
    ensure
      clients.try { |list| Autobot::Mcp.stop_all(list) }
    end

    it "starts multiple servers concurrently in background" do
      config = Autobot::Config::Config.from_yaml(<<-YAML
      mcp:
        servers:
          alpha:
            command: "mock"
          beta:
            command: "mock"
      YAML
      )
      registry = Autobot::Tools::Registry.new

      clients = Autobot::Mcp.setup(config, registry, mock_client_factory)

      sleep 0.1.seconds

      clients.size.should eq(2)
      registry.has?("mcp_alpha_mock_tool").should be_true
      registry.has?("mcp_beta_mock_tool").should be_true
    ensure
      clients.try { |list| Autobot::Mcp.stop_all(list) }
    end

    it "skips servers with failed startup without crashing" do
      config = Autobot::Config::Config.from_yaml(<<-YAML
      mcp:
        servers:
          bad:
            command: "/nonexistent/command"
      YAML
      )
      registry = Autobot::Tools::Registry.new

      clients = Autobot::Mcp.setup(config, registry)

      sleep 0.1.seconds

      clients.should be_empty
      registry.size.should eq(0)
    end

    it "skips servers with empty command" do
      config = Autobot::Config::Config.from_yaml(<<-YAML
      mcp:
        servers:
          empty:
            command: ""
      YAML
      )
      registry = Autobot::Tools::Registry.new

      clients = Autobot::Mcp.setup(config, registry)

      sleep 0.1.seconds

      clients.should be_empty
    end
  end

  describe ".stop_all" do
    it "stops all running clients" do
      config = Autobot::Config::Config.from_yaml(<<-YAML
      mcp:
        servers:
          test:
            command: "mock"
      YAML
      )
      registry = Autobot::Tools::Registry.new

      clients = Autobot::Mcp.setup(config, registry, mock_client_factory)
      sleep 0.1.seconds

      clients.size.should eq(1)
      clients.first.alive?.should be_true

      Autobot::Mcp.stop_all(clients)

      clients.first.alive?.should be_false
    end

    it "handles empty client list" do
      Autobot::Mcp.stop_all([] of Autobot::Mcp::Client)
    end
  end
end
