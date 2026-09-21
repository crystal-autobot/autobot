require "../../spec_helper"

describe Autobot::Mcp::Client do
  it "times out a slow tool call and recovers on subsequent calls" do
    script = <<-BASH
      read line
      echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{}}}'
      read line
      read line
      sleep 0.2
      echo '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"late"}]}}'
      read line
      echo '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"fast"}]}}'
    BASH

    client = Autobot::Mcp::Client.new(
      server_name: "timeout_test",
      command: "bash",
      args: ["-c", script],
      call_timeout: 50.milliseconds,
    )

    client.start
    client.alive?.should be_true

    # First request times out
    expect_raises(Exception, /timed out/) do
      client.call_tool("slow_tool", {} of String => JSON::Any)
    end

    client.alive?.should be_true

    # Allow the late response to arrive on stdout
    sleep 250.milliseconds

    # Second request succeeds; late response with id=2 is skipped, id=3 is received
    result = client.call_tool("fast_tool", {} of String => JSON::Any, timeout: 1.second)
    result.success?.should be_true
    result.content.should eq("fast")
  ensure
    client.try(&.stop)
  end

  it "stops server process and cleans up pipes on failed handshake" do
    script = "echo 'not valid json'; exit 1"

    client = Autobot::Mcp::Client.new(
      server_name: "handshake_fail",
      command: "bash",
      args: ["-c", script],
    )

    expect_raises(Exception, /closed the connection/) do
      client.start
    end

    client.alive?.should be_false
  ensure
    client.try(&.stop)
  end

  it "raises when server closes the connection" do
    script = <<-BASH
      read line
      echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{}}}'
      read line
      exit 0
    BASH

    client = Autobot::Mcp::Client.new(
      server_name: "disconnect_test",
      command: "bash",
      args: ["-c", script],
      call_timeout: 500.milliseconds,
    )

    client.start
    client.alive?.should be_true

    expect_raises(Exception, /closed the connection/) do
      client.call_tool("test_tool", {} of String => JSON::Any)
    end
  ensure
    client.try(&.stop)
  end
end
