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

      # Let background fibers complete
      sleep 0.5.seconds

      clients.size.should eq(1)
      clients.first.server_name.should eq("test")
      clients.first.alive?.should be_true
      registry.has?("mcp_test_mock_tool").should be_true
    ensure
      clients.try { |list| Autobot::Mcp.stop_all(list) }
      File.delete(script) if script && File.exists?(script)
    end

    it "starts multiple servers concurrently in background" do
      script = create_mock_server_script
      config = Autobot::Config::Config.from_yaml(<<-YAML
      mcp:
        servers:
          alpha:
            command: "bash"
            args: ["#{script}"]
          beta:
            command: "bash"
            args: ["#{script}"]
      YAML
      )
      registry = Autobot::Tools::Registry.new

      clients = Autobot::Mcp.setup(config, registry)

      sleep 0.5.seconds

      clients.size.should eq(2)
      registry.has?("mcp_alpha_mock_tool").should be_true
      registry.has?("mcp_beta_mock_tool").should be_true
    ensure
      clients.try { |list| Autobot::Mcp.stop_all(list) }
      File.delete(script) if script && File.exists?(script)
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

      sleep 0.2.seconds

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
      sleep 0.5.seconds

      clients.size.should eq(1)
      clients.first.alive?.should be_true

      Autobot::Mcp.stop_all(clients)

      clients.first.alive?.should be_false
    ensure
      File.delete(script) if script && File.exists?(script)
    end

    it "handles empty client list" do
      Autobot::Mcp.stop_all([] of Autobot::Mcp::Client)
    end
  end
end
