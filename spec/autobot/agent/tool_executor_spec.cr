require "../../spec_helper"

# Configurable mock provider for ToolExecutor tests.
# Returns a sequence of responses, one per call to chat().
# Captures sent messages for inspection in tests.
class SequenceMockProvider < Autobot::Providers::HttpProvider
  @responses : Array(String)
  @call_index : Int32 = 0
  getter call_count : Int32 = 0
  getter sent_bodies : Array(String) = [] of String

  def initialize(@responses : Array(String))
    super(api_key: "test-key", model: "mock-model")
  end

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    @call_count += 1
    @sent_bodies << body
    response_body = @responses[@call_index]? || @responses.last
    @call_index += 1
    HTTP::Client::Response.new(200, body: response_body)
  end
end

private def text_response(content : String) : String
  %({"choices":[{"message":{"content":#{content.to_json}},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}})
end

private def tool_call_response(tool_name : String, tool_id : String, arguments : String = "{}") : String
  %({"choices":[{"message":{"content":"","tool_calls":[{"id":"#{tool_id}","type":"function","function":{"name":"#{tool_name}","arguments":"#{arguments.gsub('"', "\\\"")}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}})
end

private def guardrail_response(content : String = "Content blocked by guardrail.") : String
  %({"choices":[{"message":{"content":#{content.to_json}},"finish_reason":"guardrail_intervened"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}})
end

private def create_echo_tool : Autobot::Tools::Registry
  registry = Autobot::Tools::Registry.new
  registry.register(EchoTool.new)
  registry
end

# Minimal tool that echoes input for testing.
class EchoTool < Autobot::Tools::Tool
  def name : String
    "echo"
  end

  def description : String
    "Echoes input back"
  end

  def parameters : Autobot::Tools::ToolSchema
    Autobot::Tools::ToolSchema.new(
      properties: {
        "text" => Autobot::Tools::PropertySchema.new(type: "string", description: "Text to echo"),
      },
      required: ["text"]
    )
  end

  def execute(params : Hash(String, JSON::Any)) : Autobot::Tools::ToolResult
    Autobot::Tools::ToolResult.success("Echo: #{params["text"]?.try(&.as_s) || "nil"}")
  end
end

# Tool that returns a large result for truncation tests.
class LargeOutputTool < Autobot::Tools::Tool
  def name : String
    "read_file"
  end

  def description : String
    "Returns a large result"
  end

  def parameters : Autobot::Tools::ToolSchema
    Autobot::Tools::ToolSchema.new(
      properties: {
        "path" => Autobot::Tools::PropertySchema.new(type: "string", description: "File path"),
      },
      required: ["path"]
    )
  end

  def execute(params : Hash(String, JSON::Any)) : Autobot::Tools::ToolResult
    Autobot::Tools::ToolResult.success("x" * 1000)
  end
end

# A second tool for multi-tool tests.
class MessageMockTool < Autobot::Tools::Tool
  getter? called : Bool = false

  def name : String
    "message"
  end

  def description : String
    "Send a message"
  end

  def parameters : Autobot::Tools::ToolSchema
    Autobot::Tools::ToolSchema.new(
      properties: {
        "content" => Autobot::Tools::PropertySchema.new(type: "string", description: "Message content"),
      },
      required: ["content"]
    )
  end

  def execute(params : Hash(String, JSON::Any)) : Autobot::Tools::ToolResult
    @called = true
    Autobot::Tools::ToolResult.success("Message sent")
  end
end

private def build_executor(provider : Autobot::Providers::Provider, max_iterations : Int32 = 20) : Autobot::Agent::ToolExecutor
  workspace = TestHelper.tmp_dir("tool_executor_test")
  context = Autobot::Agent::Context::Builder.new(workspace)

  Autobot::Agent::ToolExecutor.new(
    provider: provider,
    context: context,
    model: "mock-model",
    max_iterations: max_iterations
  )
end

private def build_messages(content : String = "Hello") : Array(Hash(String, JSON::Any))
  [
    {"role" => JSON::Any.new("system"), "content" => JSON::Any.new("You are a test assistant.")},
    {"role" => JSON::Any.new("user"), "content" => JSON::Any.new(content)},
  ]
end

describe Autobot::Agent::ToolExecutor do
  describe "#execute" do
    it "returns text content when LLM responds without tool calls" do
      provider = SequenceMockProvider.new([text_response("Hello, world!")])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new

      result = executor.execute(build_messages, tools)

      result.content.should eq("Hello, world!")
      result.tools_used.should be_empty
      result.total_tokens.should eq(15)
      provider.call_count.should eq(1)
    end

    it "executes tool calls and returns final text response" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"ping"})),
        text_response("Done!"),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      result = executor.execute(build_messages, tools)

      result.content.should eq("Done!")
      result.tools_used.should eq(["echo"])
      result.total_tokens.should eq(30) # 15 + 15
      provider.call_count.should eq(2)
    end

    it "handles multiple iterations of tool calls" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"step1"})),
        tool_call_response("echo", "tc_2", %({"text":"step2"})),
        text_response("All done."),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      result = executor.execute(build_messages, tools)

      result.content.should eq("All done.")
      result.tools_used.should eq(["echo"])
      provider.call_count.should eq(3)
    end

    it "respects max_iterations and returns nil content when exhausted" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"loop"})),
      ])
      executor = build_executor(provider, max_iterations: 2)
      tools = create_echo_tool

      result = executor.execute(build_messages, tools)

      result.content.should be_nil
      result.tools_used.should eq(["echo"])
      provider.call_count.should eq(2)
    end

    it "stops on guardrail intervention" do
      provider = SequenceMockProvider.new([guardrail_response("Blocked.")])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new

      result = executor.execute(build_messages, tools)

      result.content.should eq("Blocked.")
      result.tools_used.should be_empty
      provider.call_count.should eq(1)
    end

    it "excludes tools from LLM definitions" do
      provider = SequenceMockProvider.new([text_response("OK")])
      executor = build_executor(provider)

      tools = Autobot::Tools::Registry.new
      tools.register(EchoTool.new)
      tools.register(MessageMockTool.new)

      # Exclude "echo" - the LLM won't see it, but execute should still work
      result = executor.execute(build_messages, tools, exclude_tools: ["echo"])

      result.content.should eq("OK")
    end

    it "stops after specified tool with stop_after_tool" do
      provider = SequenceMockProvider.new([
        tool_call_response("message", "tc_1", %({"content":"hello"})),
        text_response("This should not be reached"),
      ])
      executor = build_executor(provider)

      message_tool = MessageMockTool.new
      tools = Autobot::Tools::Registry.new
      tools.register(message_tool)

      result = executor.execute(build_messages, tools, stop_after_tool: "message")

      message_tool.called?.should be_true
      result.tools_used.should eq(["message"])
      # Only one LLM call - stops after the tool executes
      provider.call_count.should eq(1)
      # Content is nil because we broke before getting a text response
      result.content.should be_nil
    end

    it "does not stop for non-matching tools when stop_after_tool is set" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"not message"})),
        text_response("Continued."),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      result = executor.execute(build_messages, tools, stop_after_tool: "message")

      result.content.should eq("Continued.")
      result.tools_used.should eq(["echo"])
      provider.call_count.should eq(2)
    end

    it "passes session_key to tools for rate limiting" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"test"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      result = executor.execute(build_messages, tools, session_key: "test:session")

      result.content.should eq("Done")
      result.tools_used.should eq(["echo"])
    end

    it "deduplicates tools_used across iterations" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"a"})),
        tool_call_response("echo", "tc_2", %({"text":"b"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      result = executor.execute(build_messages, tools)

      result.tools_used.should eq(["echo"])
    end

    it "preserves distinct tool names in tools_used" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"a"})),
        tool_call_response("message", "tc_2", %({"content":"b"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new
      tools.register(EchoTool.new)
      tools.register(MessageMockTool.new)

      result = executor.execute(build_messages, tools)

      result.tools_used.should eq(["echo", "message"])
    end

    it "accumulates tokens across iterations" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"a"})),
        tool_call_response("echo", "tc_2", %({"text":"b"})),
        tool_call_response("echo", "tc_3", %({"text":"c"})),
        text_response("Final"),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      result = executor.execute(build_messages, tools)

      result.total_tokens.should eq(60) # 15 * 4
    end
  end

  describe "tool result truncation" do
    it "truncates large tool results from old iterations" do
      # 3 iterations: read_file (large) -> read_file (large) -> text response
      provider = SequenceMockProvider.new([
        tool_call_response("read_file", "tc_1", %({"path":"a.cr"})),
        tool_call_response("read_file", "tc_2", %({"path":"b.cr"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new
      tools.register(LargeOutputTool.new)

      result = executor.execute(build_messages, tools)
      result.content.should eq("Done")

      # On the 3rd LLM call, the first iteration's tool result should be truncated.
      # Parse the messages sent in the last request body.
      last_body = JSON.parse(provider.sent_bodies.last)
      messages = last_body["messages"].as_a

      # Find tool result messages
      tool_results = messages.select { |msg| msg["role"]?.try(&.as_s?) == "tool" }
      tool_results.size.should eq(2)

      # First tool result (old) should be truncated
      first_result = tool_results[0]["content"].as_s
      first_result.should contain("truncated")
      first_result.should contain("read_file")

      # Second tool result (recent) should be intact
      second_result = tool_results[1]["content"].as_s
      second_result.should eq("x" * 1000)
    end

    it "preserves small tool results even from old iterations" do
      # 3 iterations with small results — nothing should be truncated
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"small"})),
        tool_call_response("echo", "tc_2", %({"text":"also small"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      result = executor.execute(build_messages, tools)
      result.content.should eq("Done")

      last_body = JSON.parse(provider.sent_bodies.last)
      messages = last_body["messages"].as_a

      tool_results = messages.select { |msg| msg["role"]?.try(&.as_s?) == "tool" }
      tool_results.each do |tool_result|
        tool_result["content"].as_s.should_not contain("truncated")
      end
    end

    it "does not truncate on first or second iteration" do
      # 2 iterations: one tool call then text. No truncation should happen.
      provider = SequenceMockProvider.new([
        tool_call_response("read_file", "tc_1", %({"path":"a.cr"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new
      tools.register(LargeOutputTool.new)

      result = executor.execute(build_messages, tools)
      result.content.should eq("Done")

      # Second call should still have the full tool result
      last_body = JSON.parse(provider.sent_bodies.last)
      messages = last_body["messages"].as_a

      tool_results = messages.select { |msg| msg["role"]?.try(&.as_s?) == "tool" }
      tool_results.size.should eq(1)
      tool_results[0]["content"].as_s.should eq("x" * 1000)
    end

    it "truncates multiple old iterations while keeping the latest" do
      # 4 iterations: 3 tool calls then text
      provider = SequenceMockProvider.new([
        tool_call_response("read_file", "tc_1", %({"path":"a.cr"})),
        tool_call_response("read_file", "tc_2", %({"path":"b.cr"})),
        tool_call_response("read_file", "tc_3", %({"path":"c.cr"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new
      tools.register(LargeOutputTool.new)

      result = executor.execute(build_messages, tools)
      result.content.should eq("Done")

      last_body = JSON.parse(provider.sent_bodies.last)
      messages = last_body["messages"].as_a

      tool_results = messages.select { |msg| msg["role"]?.try(&.as_s?) == "tool" }
      tool_results.size.should eq(3)

      # First two (old iterations) should be truncated
      tool_results[0]["content"].as_s.should contain("truncated")
      tool_results[1]["content"].as_s.should contain("truncated")

      # Last one (most recent iteration) should be intact
      tool_results[2]["content"].as_s.should eq("x" * 1000)
    end
  end

  describe "progressive tool disclosure" do
    it "sends full tool definitions on first iteration" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"hi"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      executor.execute(build_messages, tools)

      # First call should include full tool description
      first_body = JSON.parse(provider.sent_bodies.first)
      tool_defs = first_body["tools"].as_a
      tool_defs.size.should eq(1)
      tool_defs[0]["function"]["description"].as_s.should eq("Echoes input back")
    end

    it "sends compact schemas for called tools on subsequent iterations" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"a"})),
        tool_call_response("echo", "tc_2", %({"text":"b"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      executor.execute(build_messages, tools)

      # Third call (after echo was called): echo should be compact
      third_body = JSON.parse(provider.sent_bodies[2])
      tool_defs = third_body["tools"].as_a
      tool_defs.size.should eq(1)
      tool_defs[0]["function"]["name"].as_s.should eq("echo")
      tool_defs[0]["function"]["description"]?.should be_nil
    end

    it "keeps full schema for uncalled tools while compacting called ones" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"a"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new
      tools.register(EchoTool.new)
      tools.register(MessageMockTool.new)

      executor.execute(build_messages, tools)

      # Second call: echo was called, message was not
      second_body = JSON.parse(provider.sent_bodies[1])
      tool_defs = second_body["tools"].as_a

      echo_def = tool_defs.find! { |tool_def| tool_def["function"]["name"].as_s == "echo" }
      message_def = tool_defs.find! { |tool_def| tool_def["function"]["name"].as_s == "message" }

      # Echo should be compact (no description)
      echo_def["function"]["description"]?.should be_nil

      # Message should still have full description
      message_def["function"]["description"].as_s.should eq("Send a message")
    end
  end
end
