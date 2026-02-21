require "../../spec_helper"

# Mock provider that returns a simple text response (no tool calls).
class MockProvider < Autobot::Providers::HttpProvider
  def initialize
    super(api_key: "test-key", model: "mock-model")
  end

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    HTTP::Client::Response.new(200, body: %({"choices":[{"message":{"content":"Mock response"},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}))
  end
end

# Mock provider that returns a tool call with reasoning_content on the first call,
# then a final text response on the second call.
class ToolCallWithReasoningProvider < Autobot::Providers::HttpProvider
  getter call_count : Int32 = 0

  def initialize
    super(api_key: "test-key", model: "mock-model")
  end

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    @call_count += 1
    if @call_count == 1
      HTTP::Client::Response.new(200, body: %({"choices":[{"message":{"content":"thinking...","reasoning_content":"deep reasoning here","tool_calls":[{"id":"tc1","type":"function","function":{"name":"exec","arguments":"{\\"command\\":\\"echo hi\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}))
    else
      HTTP::Client::Response.new(200, body: %({"choices":[{"message":{"content":"Final answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}))
    end
  end
end

# Mock provider that tracks whether streaming was used.
class StreamingTrackingProvider < Autobot::Providers::HttpProvider
  getter? streaming_used : Bool = false

  def initialize
    super(api_key: "test-key", model: "mock-model")
  end

  def chat_streaming(
    messages : Array(Hash(String, JSON::Any)),
    tools : Array(Hash(String, JSON::Any))? = nil,
    model : String? = nil,
    max_tokens : Int32 = Autobot::Providers::DEFAULT_MAX_TOKENS,
    temperature : Float64 = Autobot::Providers::DEFAULT_TEMPERATURE,
    &on_delta : Autobot::Providers::StreamCallback
  ) : Autobot::Providers::Response
    @streaming_used = true
    on_delta.call("Mock streaming response")
    Autobot::Providers::Response.new(
      content: "Mock streaming response",
      finish_reason: "stop",
      usage: Autobot::Providers::TokenUsage.new,
    )
  end

  private def http_post(url : String, headers : HTTP::Headers, body : String) : HTTP::Client::Response
    HTTP::Client::Response.new(200, body: %({"choices":[{"message":{"content":"Mock response"},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}))
  end
end

# Testable subclass exposing private methods for unit testing.
class TestableLoop < Autobot::Agent::Loop
  def test_build_cron_prompt(msg : Autobot::Bus::InboundMessage) : String
    build_cron_prompt(msg)
  end

  def test_process_message(msg : Autobot::Bus::InboundMessage) : Autobot::Bus::OutboundMessage?
    process_message(msg)
  end
end

private def create_test_loop(
  workspace : Path,
  cron_service : Autobot::Cron::Service? = nil,
  tools : Autobot::Tools::Registry? = nil,
) : TestableLoop
  bus = Autobot::Bus::MessageBus.new(capacity: 10)
  provider = MockProvider.new
  tool_registry = tools || Autobot::Tools::Registry.new
  sessions = Autobot::Session::Manager.new(workspace)

  # Register message tool so it can be wired
  tool_registry.register(Autobot::Tools::MessageTool.new)

  TestableLoop.new(
    bus: bus,
    provider: provider,
    workspace: workspace,
    tools: tool_registry,
    sessions: sessions,
    cron_service: cron_service,
    memory_window: 0,
    sandbox_config: "none"
  )
end

describe Autobot::Agent::Loop do
  describe "#build_cron_prompt" do
    it "includes the task message" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)
      msg = Autobot::Bus::InboundMessage.new(
        channel: Autobot::Constants::CHANNEL_SYSTEM,
        sender_id: "cron:job123",
        chat_id: "telegram:user1",
        content: "Check weather forecast"
      )

      prompt = loop_inst.test_build_cron_prompt(msg)
      prompt.should contain("Check weather forecast")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "includes the job ID" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)
      msg = Autobot::Bus::InboundMessage.new(
        channel: Autobot::Constants::CHANNEL_SYSTEM,
        sender_id: "cron:abc12345",
        chat_id: "telegram:user1",
        content: "Check something"
      )

      prompt = loop_inst.test_build_cron_prompt(msg)
      prompt.should contain("abc12345")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "instructs not to create new cron jobs" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)
      msg = Autobot::Bus::InboundMessage.new(
        channel: Autobot::Constants::CHANNEL_SYSTEM,
        sender_id: "cron:xyz789",
        chat_id: "telegram:user1",
        content: "Monitor file"
      )

      prompt = loop_inst.test_build_cron_prompt(msg)
      prompt.should contain("Do NOT create new cron jobs")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "instructs to use message tool for delivery" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)
      msg = Autobot::Bus::InboundMessage.new(
        channel: Autobot::Constants::CHANNEL_SYSTEM,
        sender_id: "cron:xyz789",
        chat_id: "telegram:user1",
        content: "Monitor file"
      )

      prompt = loop_inst.test_build_cron_prompt(msg)
      prompt.should contain("message")
      prompt.should contain("deliver results")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "instructs to stay silent when nothing to report" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)
      msg = Autobot::Bus::InboundMessage.new(
        channel: Autobot::Constants::CHANNEL_SYSTEM,
        sender_id: "cron:xyz789",
        chat_id: "telegram:user1",
        content: "Monitor file"
      )

      prompt = loop_inst.test_build_cron_prompt(msg)
      prompt.should contain("nothing to report")
      prompt.should contain("do NOT send a message")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "instructs not to remove job unless stop condition met" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)
      msg = Autobot::Bus::InboundMessage.new(
        channel: Autobot::Constants::CHANNEL_SYSTEM,
        sender_id: "cron:stop123",
        chat_id: "telegram:user1",
        content: "Check state"
      )

      prompt = loop_inst.test_build_cron_prompt(msg)
      prompt.should contain("Do NOT remove this job")
      prompt.should contain("stop condition")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "BACKGROUND_EXCLUDED_TOOLS" do
    it "excludes spawn from background turns" do
      excluded = Autobot::Agent::Loop::BACKGROUND_EXCLUDED_TOOLS
      excluded.should contain("spawn")
    end

    it "does not exclude message tool (allows conditional delivery)" do
      excluded = Autobot::Agent::Loop::BACKGROUND_EXCLUDED_TOOLS
      excluded.should_not contain("message")
    end
  end

  describe "#process_message" do
    it "suppresses auto-delivery for cron turns" do
      tmp = TestHelper.tmp_dir
      cron = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      loop_inst = create_test_loop(workspace: tmp, cron_service: cron)

      msg = Autobot::Bus::InboundMessage.new(
        channel: Autobot::Constants::CHANNEL_SYSTEM,
        sender_id: "cron:somejob",
        chat_id: "telegram:user1",
        content: "Cron task"
      )

      response = loop_inst.test_process_message(msg)
      response.should be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns outbound message for non-cron system messages" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)

      msg = Autobot::Bus::InboundMessage.new(
        channel: Autobot::Constants::CHANNEL_SYSTEM,
        sender_id: "subagent:task1",
        chat_id: "telegram:user1",
        content: "Subagent result"
      )

      response = loop_inst.test_process_message(msg)
      response.should_not be_nil
      response.try(&.channel).should eq("telegram")
      response.try(&.chat_id).should eq("user1")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns outbound message for regular messages" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)

      msg = Autobot::Bus::InboundMessage.new(
        channel: "telegram",
        sender_id: "user1",
        chat_id: "chat1",
        content: "Hello"
      )

      response = loop_inst.test_process_message(msg)
      response.should_not be_nil
      response.try(&.content).should eq("Mock response")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "preserves inbound metadata in outbound response" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)

      msg = Autobot::Bus::InboundMessage.new(
        channel: "slack",
        sender_id: "U12345",
        chat_id: "C67890",
        content: "Hello from Slack",
        metadata: {
          "thread_ts"    => "1234567890.123456",
          "channel_type" => "channel",
        },
      )

      response = loop_inst.test_process_message(msg)
      response.should_not be_nil
      response.try(&.metadata["thread_ts"]).should eq("1234567890.123456")
      response.try(&.metadata["channel_type"]).should eq("channel")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "message tool wiring" do
    it "wires message tool send_callback to bus" do
      tmp = TestHelper.tmp_dir
      tools = Autobot::Tools::Registry.new
      tools.register(Autobot::Tools::MessageTool.new)

      create_test_loop(workspace: tmp, tools: tools)

      # Message tool should now have send_callback set
      message_tool = tools.get("message").as?(Autobot::Tools::MessageTool)
      message_tool.should_not be_nil

      # Executing message tool should succeed (not "Message sending not configured")
      result = message_tool.as(Autobot::Tools::MessageTool).execute({
        "content" => JSON::Any.new("Test message"),
        "channel" => JSON::Any.new("telegram"),
        "chat_id" => JSON::Any.new("user1"),
      })
      result.success?.should be_true
      result.content.should contain("Message sent")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "cron tool registration" do
    it "registers cron tool when cron_service is provided" do
      tmp = TestHelper.tmp_dir
      cron = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tools = Autobot::Tools::Registry.new
      tools.register(Autobot::Tools::MessageTool.new)

      create_test_loop(workspace: tmp, cron_service: cron, tools: tools)

      tools.has?("cron").should be_true
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "does not register cron tool when no cron_service" do
      tmp = TestHelper.tmp_dir
      tools = Autobot::Tools::Registry.new
      tools.register(Autobot::Tools::MessageTool.new)

      create_test_loop(workspace: tmp, cron_service: nil, tools: tools)

      tools.has?("cron").should be_false
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "streaming_callback_factory" do
    it "is nil by default" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)
      loop_inst.streaming_callback_factory.should be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "can be set to a factory proc" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)

      factory = ->(_channel : String, _chat_id : String) : Autobot::Providers::StreamCallback? {
        Autobot::Providers::StreamCallback.new { |_delta| }
      }
      loop_inst.streaming_callback_factory = factory
      loop_inst.streaming_callback_factory.should_not be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "factory returns nil for non-matching channels" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)

      factory = ->(channel : String, _chat_id : String) : Autobot::Providers::StreamCallback? {
        return nil unless channel == "telegram"
        Autobot::Providers::StreamCallback.new { |_delta| }
      }
      loop_inst.streaming_callback_factory = factory

      callback = factory.call("slack", "chat1")
      callback.should be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "factory returns callback for matching channel" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)

      factory = ->(channel : String, _chat_id : String) : Autobot::Providers::StreamCallback? {
        return nil unless channel == "telegram"
        Autobot::Providers::StreamCallback.new { |_delta| }
      }
      loop_inst.streaming_callback_factory = factory

      callback = factory.call("telegram", "chat1")
      callback.should_not be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "reasoning_content preservation" do
    it "preserves reasoning_content through tool call iterations" do
      tmp = TestHelper.tmp_dir
      provider = ToolCallWithReasoningProvider.new
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      tool_registry = Autobot::Tools::Registry.new
      tool_registry.register(Autobot::Tools::MessageTool.new)
      sessions = Autobot::Session::Manager.new(tmp)

      loop_inst = TestableLoop.new(
        bus: bus,
        provider: provider,
        workspace: tmp,
        tools: tool_registry,
        sessions: sessions,
        memory_window: 0,
        sandbox_config: "none"
      )

      msg = Autobot::Bus::InboundMessage.new(
        channel: "telegram",
        sender_id: "user1",
        chat_id: "chat1",
        content: "test"
      )

      response = loop_inst.test_process_message(msg)
      response.should_not be_nil
      # Provider should have been called twice: tool call + final answer
      provider.call_count.should eq(2)
      response.try(&.content).should eq("Final answer")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "streaming integration" do
    it "uses streaming provider when factory is configured" do
      tmp = TestHelper.tmp_dir
      provider = StreamingTrackingProvider.new
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      tool_registry = Autobot::Tools::Registry.new
      tool_registry.register(Autobot::Tools::MessageTool.new)
      sessions = Autobot::Session::Manager.new(tmp)

      loop_inst = TestableLoop.new(
        bus: bus,
        provider: provider,
        workspace: tmp,
        tools: tool_registry,
        sessions: sessions,
        memory_window: 0,
        sandbox_config: "none"
      )

      # Set up a streaming factory that returns a callback for telegram
      loop_inst.streaming_callback_factory = ->(channel : String, _chat_id : String) : Autobot::Providers::StreamCallback? {
        return nil unless channel == "telegram"
        Autobot::Providers::StreamCallback.new { |_delta| }
      }

      msg = Autobot::Bus::InboundMessage.new(
        channel: "telegram",
        sender_id: "user1",
        chat_id: "chat1",
        content: "Hello"
      )

      response = loop_inst.test_process_message(msg)
      response.should_not be_nil
      provider.streaming_used?.should be_true
      response.try(&.content).should eq("Mock streaming response")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "does not use streaming for non-matching channels" do
      tmp = TestHelper.tmp_dir
      provider = StreamingTrackingProvider.new
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      tool_registry = Autobot::Tools::Registry.new
      tool_registry.register(Autobot::Tools::MessageTool.new)
      sessions = Autobot::Session::Manager.new(tmp)

      loop_inst = TestableLoop.new(
        bus: bus,
        provider: provider,
        workspace: tmp,
        tools: tool_registry,
        sessions: sessions,
        memory_window: 0,
        sandbox_config: "none"
      )

      # Factory only returns callback for telegram
      loop_inst.streaming_callback_factory = ->(channel : String, _chat_id : String) : Autobot::Providers::StreamCallback? {
        return nil unless channel == "telegram"
        Autobot::Providers::StreamCallback.new { |_delta| }
      }

      msg = Autobot::Bus::InboundMessage.new(
        channel: "slack",
        sender_id: "user1",
        chat_id: "chat1",
        content: "Hello"
      )

      response = loop_inst.test_process_message(msg)
      response.should_not be_nil
      provider.streaming_used?.should be_false
      response.try(&.content).should eq("Mock response")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end
end
