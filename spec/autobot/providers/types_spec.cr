require "../../spec_helper"

describe Autobot::Providers::TokenUsage do
  it "creates zero usage" do
    usage = Autobot::Providers::TokenUsage.new
    usage.prompt_tokens.should eq(0)
    usage.completion_tokens.should eq(0)
    usage.total_tokens.should eq(0)
    usage.zero?.should be_true
  end

  it "creates non-zero usage" do
    usage = Autobot::Providers::TokenUsage.new(
      prompt_tokens: 100,
      completion_tokens: 50,
      total_tokens: 150
    )
    usage.prompt_tokens.should eq(100)
    usage.completion_tokens.should eq(50)
    usage.total_tokens.should eq(150)
    usage.zero?.should be_false
  end

  it "serializes to JSON" do
    usage = Autobot::Providers::TokenUsage.new(
      prompt_tokens: 10,
      completion_tokens: 20,
      total_tokens: 30
    )
    json = usage.to_json
    parsed = Autobot::Providers::TokenUsage.from_json(json)
    parsed.total_tokens.should eq(30)
  end

  it "tracks cache tokens" do
    usage = Autobot::Providers::TokenUsage.new(
      prompt_tokens: 100,
      completion_tokens: 50,
      total_tokens: 150,
      cache_creation_tokens: 80,
      cache_read_tokens: 0,
    )
    usage.cache_creation_tokens.should eq(80)
    usage.cache_read_tokens.should eq(0)
    usage.cached?.should be_true
  end

  it "reports not cached when no cache tokens" do
    usage = Autobot::Providers::TokenUsage.new(
      prompt_tokens: 100,
      completion_tokens: 50,
      total_tokens: 150,
    )
    usage.cached?.should be_false
  end
end

describe Autobot::Providers::ToolCall do
  it "creates a tool call" do
    call = Autobot::Providers::ToolCall.new(
      id: "call_123",
      name: "read_file",
      arguments: {"path" => JSON::Any.new("/tmp/test.txt")}
    )

    call.id.should eq("call_123")
    call.name.should eq("read_file")
    call.arguments["path"].as_s.should eq("/tmp/test.txt")
  end

  it "creates a tool call with empty arguments" do
    call = Autobot::Providers::ToolCall.new(id: "call_456", name: "status")
    call.arguments.should be_empty
  end

  it "serializes to JSON" do
    call = Autobot::Providers::ToolCall.new(
      id: "c1",
      name: "exec",
      arguments: {"command" => JSON::Any.new("ls")}
    )
    json = call.to_json
    parsed = Autobot::Providers::ToolCall.from_json(json)
    parsed.name.should eq("exec")
  end
end

describe Autobot::Providers::Response do
  it "creates a text response" do
    response = Autobot::Providers::Response.new(
      content: "Hello!",
      finish_reason: "stop"
    )
    response.content.should eq("Hello!")
    response.has_tool_calls?.should be_false
    response.error?.should be_false
  end

  it "creates a tool-calling response" do
    tool_call = Autobot::Providers::ToolCall.new(
      id: "tc1",
      name: "read_file",
      arguments: {"path" => JSON::Any.new("test.cr")}
    )
    response = Autobot::Providers::Response.new(
      tool_calls: [tool_call],
      finish_reason: "tool_use"
    )
    response.has_tool_calls?.should be_true
    response.tool_calls.size.should eq(1)
    response.tool_calls[0].name.should eq("read_file")
  end

  it "detects error responses" do
    response = Autobot::Providers::Response.new(
      content: "Rate limited",
      finish_reason: "error"
    )
    response.error?.should be_true
  end

  it "tracks token usage" do
    response = Autobot::Providers::Response.new(
      content: "reply",
      usage: Autobot::Providers::TokenUsage.new(
        prompt_tokens: 500,
        completion_tokens: 200,
        total_tokens: 700
      )
    )
    response.usage.total_tokens.should eq(700)
  end

  it "supports reasoning content" do
    response = Autobot::Providers::Response.new(
      content: "Answer",
      reasoning_content: "I think step by step..."
    )
    response.reasoning_content.should eq("I think step by step...")
  end
end
