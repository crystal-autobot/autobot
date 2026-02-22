require "../../spec_helper"

# Configurable mock provider for ToolExecutor tests.
# Returns a sequence of responses, one per call to chat().
class SequenceMockProvider < Autobot::Providers::HttpProvider
  @responses : Array(String)
  @call_index : Int32 = 0
  getter call_count : Int32 = 0

  def initialize(@responses : Array(String))
    super(api_key: "test-key", model: "mock-model")
  end

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    @call_count += 1
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
end
