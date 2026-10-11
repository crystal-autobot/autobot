require "../../spec_helper"

private INIT_RESPONSE = %({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{}}})

private def text_response(id : Int32, text : String) : String
  %({"jsonrpc":"2.0","id":#{id},"result":{"content":[{"type":"text","text":"#{text}"}]}})
end

private def start_client(name : String, script : String, call_timeout : Time::Span = 1.second) : Autobot::Mcp::Client
  client = Autobot::Mcp::Client.new(
    server_name: name,
    command: "bash",
    args: ["-c", script],
    call_timeout: call_timeout,
  )
  client.start
  client
end

describe Autobot::Mcp::Client do
  it "times out a slow tool call, cancels it and recovers on subsequent calls" do
    script = <<-BASH
      read line
      echo '#{INIT_RESPONSE}'
      read line
      read line
      read cancel
      echo '#{text_response(2, "late")}'
      read line
      echo "$cancel" | grep -q notifications/cancelled && echo '#{text_response(3, "fast")}'
    BASH

    client = start_client("timeout_test", script, call_timeout: 50.milliseconds)
    client.alive?.should be_true

    expect_raises(Exception, /timed out/) do
      client.call_tool("slow_tool", {} of String => JSON::Any)
    end

    client.alive?.should be_true

    result = client.call_tool("fast_tool", {} of String => JSON::Any, timeout: 1.second)
    result.success?.should be_true
    result.content.should eq("fast")
  ensure
    client.try(&.stop)
  end

  it "survives stdout lines that are not JSON objects" do
    script = <<-BASH
      read line
      echo 'starting up'
      echo '42'
      echo 'null'
      echo '#{INIT_RESPONSE}'
      read line
      read line
      echo '#{text_response(2, "ok")}'
    BASH

    client = start_client("noise_test", script)

    result = client.call_tool("tool", {} of String => JSON::Any)
    result.content.should eq("ok")
    client.alive?.should be_true
  ensure
    client.try(&.stop)
  end

  it "returns an error reply whose id is null to the caller" do
    script = <<-BASH
      read line
      echo '#{INIT_RESPONSE}'
      read line
      read line
      echo '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}'
    BASH

    client = start_client("null_id_test", script)

    result = client.call_tool("tool", {} of String => JSON::Any)
    result.success?.should be_false
    result.content.should eq("Error: Parse error")
  ensure
    client.try(&.stop)
  end

  it "stops server process and cleans up pipes on failed handshake" do
    client = Autobot::Mcp::Client.new(
      server_name: "handshake_fail",
      command: "bash",
      args: ["-c", "echo 'not valid json'; exit 1"],
    )

    expect_raises(Exception, /closed the connection/) do
      client.start
    end

    client.alive?.should be_false
  ensure
    client.try(&.stop)
  end

  it "fails to start when the server rejects the handshake" do
    script = <<-BASH
      read line
      echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Unsupported protocol version"}}'
      exec sleep 5
    BASH

    client = Autobot::Mcp::Client.new(server_name: "handshake_reject", command: "bash", args: ["-c", script])

    expect_raises(Exception, /Unsupported protocol version/) do
      client.start
    end

    client.alive?.should be_false
  ensure
    client.try(&.stop)
  end

  it "raises when server closes the connection" do
    script = <<-BASH
      read line
      echo '#{INIT_RESPONSE}'
      read line
      exit 0
    BASH

    client = start_client("disconnect_test", script, call_timeout: 500.milliseconds)
    client.alive?.should be_true

    expect_raises(Exception, /closed the connection/) do
      client.call_tool("test_tool", {} of String => JSON::Any)
    end
  ensure
    client.try(&.stop)
  end
end
