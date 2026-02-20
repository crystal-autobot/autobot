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
    it "includes the original message" do
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

    it "returns the original message content" do
      tmp = TestHelper.tmp_dir
      loop_inst = create_test_loop(workspace: tmp)
      msg = Autobot::Bus::InboundMessage.new(
        channel: Autobot::Constants::CHANNEL_SYSTEM,
        sender_id: "cron:abc12345",
        chat_id: "telegram:user1",
        content: "Check something"
      )

      prompt = loop_inst.test_build_cron_prompt(msg)
      prompt.should eq("Check something")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "#process_message" do
    it "auto-delivers cron system messages" do
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
      response.should_not be_nil
      response.try(&.channel).should eq("telegram")
      response.try(&.chat_id).should eq("user1")
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
end
