require "../../spec_helper"

# Configurable mock provider for ToolExecutor tests.
# Returns a sequence of responses, one per call to chat().
# Captures sent messages for inspection in tests.
class SequenceMockProvider < Autobot::Providers::HttpProvider
  @responses : Array(String)
  @call_index : Int32 = 0
  getter call_count : Int32 = 0
  getter sent_bodies : Array(String) = [] of String

  def initialize(@responses : Array(String), provider_name : String? = nil)
    super(api_key: "test-key", model: "mock-model", provider_name: provider_name)
  end

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    @call_count += 1
    @sent_bodies << body
    response_body = @responses[@call_index]? || @responses.last
    @call_index += 1
    HTTP::Client::Response.new(200, body: response_body)
  end
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

class RefusingTool < Autobot::Tools::Tool
  def name : String
    "refusing"
  end

  def description : String
    "Refuses every call"
  end

  def parameters : Autobot::Tools::ToolSchema
    Autobot::Tools::ToolSchema.new
  end

  def execute(params : Hash(String, JSON::Any)) : Autobot::Tools::ToolResult
    Autobot::Tools::ToolResult.error("could not post")
  end
end

class LargeOutputTool < Autobot::Tools::Tool
  def initialize(@size : Int32 = 1000)
  end

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
    Autobot::Tools::ToolResult.success("x" * @size)
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
    it "passes configured max_tokens and temperature to provider" do
      provider = SequenceMockProvider.new([text_response("Hello, world!")])
      workspace = TestHelper.tmp_dir("tool_executor_params_test")
      context = Autobot::Agent::Context::Builder.new(workspace)
      executor = Autobot::Agent::ToolExecutor.new(
        provider: provider,
        context: context,
        model: "mock-model",
        max_tokens: 32768,
        temperature: 0.7
      )
      tools = Autobot::Tools::Registry.new

      result = executor.execute(build_messages, tools)

      result.content.should eq("Hello, world!")
      provider.sent_bodies.size.should eq(1)
      sent_json = JSON.parse(provider.sent_bodies.first)
      sent_json["max_tokens"].as_i.should eq(32768)
      sent_json["temperature"].as_f.should eq(0.7)
    ensure
      FileUtils.rm_rf(workspace) if workspace
    end

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

    it "ends the turn after a listed tool succeeds" do
      provider = SequenceMockProvider.new([
        tool_call_response("message", "tc_1", %({"content":"hello"})),
        text_response("This should not be reached"),
      ])
      executor = build_executor(provider)

      message_tool = MessageMockTool.new
      tools = Autobot::Tools::Registry.new
      tools.register(message_tool)

      result = executor.execute(build_messages, tools, stop_after: ["message"])

      message_tool.called?.should be_true
      result.tools_used.should eq(["message"])
      result.stop_output.should_not be_nil
      provider.call_count.should eq(1)
      result.content.should be_nil
    end

    it "lets the model continue after a listed tool fails" do
      provider = SequenceMockProvider.new([
        tool_call_response("refusing", "tc_1"),
        text_response("I could not post that"),
      ])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new
      tools.register(RefusingTool.new)

      result = executor.execute(build_messages, tools, stop_after: ["refusing"])

      result.stop_output.should be_nil
      result.content.should eq("I could not post that")
      provider.call_count.should eq(2)
    end

    it "does not stop for tools that are not listed" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"not message"})),
        text_response("Continued."),
      ])
      executor = build_executor(provider)
      tools = create_echo_tool

      result = executor.execute(build_messages, tools, stop_after: ["message"])

      result.stop_output.should be_nil
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

  describe "stable request prefix" do
    it "never rewrites earlier messages inside a tool loop" do
      provider = SequenceMockProvider.new([
        tool_call_response("read_file", "tc_1", %({"path":"a.cr"})),
        tool_call_response("read_file", "tc_2", %({"path":"b.cr"})),
        tool_call_response("read_file", "tc_3", %({"path":"c.cr"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new
      tools.register(LargeOutputTool.new)

      executor.execute(build_messages, tools).content.should eq("Done")

      sent_messages = provider.sent_bodies.map { |body| JSON.parse(body)["messages"].as_a }
      sent_messages.each_cons_pair do |earlier, later|
        later[0, earlier.size].should eq(earlier)
      end
      tool_results = sent_messages.last.select { |msg| msg["role"].as_s == "tool" }
      tool_results.map(&.["content"].as_s).should eq(["x" * 1000] * 3)
    end

    it "caps an oversized tool result once and keeps it identical afterwards" do
      max = Autobot::Agent::ToolExecutor::MAX_TOOL_RESULT_CHARS
      provider = SequenceMockProvider.new([
        tool_call_response("read_file", "tc_1", %({"path":"big.log"})),
        tool_call_response("read_file", "tc_2", %({"path":"small.log"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new
      tools.register(LargeOutputTool.new(max + 5_000))

      executor.execute(build_messages, tools).content.should eq("Done")

      capped = "#{"x" * max}\n... (result truncated at #{max} of #{max + 5_000} chars)"
      first_results = provider.sent_bodies.map do |body|
        tool_message = JSON.parse(body)["messages"].as_a.find { |msg| msg["role"].as_s == "tool" }
        tool_message.try(&.["content"].as_s)
      end
      first_results.should eq([nil, capped, capped])
    end

    it "sends identical full tool definitions on every iteration" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"a"})),
        tool_call_response("message", "tc_2", %({"content":"b"})),
        text_response("Done"),
      ])
      executor = build_executor(provider)
      tools = Autobot::Tools::Registry.new
      tools.register(EchoTool.new)
      tools.register(MessageMockTool.new)

      executor.execute(build_messages, tools)

      sent_tools = provider.sent_bodies.map { |body| JSON.parse(body)["tools"].to_json }
      sent_tools.size.should eq(3)
      sent_tools.uniq.should eq([tools.definitions.to_json])
    end

    it "sends a prompt cache key derived from the session key" do
      provider = SequenceMockProvider.new([
        tool_call_response("echo", "tc_1", %({"text":"a"})),
        text_response("Done"),
      ], provider_name: "openai")
      executor = build_executor(provider)

      executor.execute(build_messages, create_echo_tool, session_key: "telegram:42")

      keys = provider.sent_bodies.map { |body| JSON.parse(body)["prompt_cache_key"].as_s }
      keys.should eq([Digest::SHA256.hexdigest("telegram:42")] * 2)
    end

    it "sends no prompt cache key without a session key" do
      provider = SequenceMockProvider.new([text_response("Done")], provider_name: "openai")
      executor = build_executor(provider)

      executor.execute(build_messages, create_echo_tool)

      JSON.parse(provider.sent_bodies.first)["prompt_cache_key"]?.should be_nil
    end
  end
end
