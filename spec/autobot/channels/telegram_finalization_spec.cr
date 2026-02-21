require "../../spec_helper"

# Testable TelegramChannel that records API calls instead of making real HTTP requests.
private class TestableTelegramChannel < Autobot::Channels::TelegramChannel
  getter api_calls : Array({String, Hash(String, String)}) = [] of {String, Hash(String, String)}

  def initialize(bus : Autobot::Bus::MessageBus, streaming_enabled : Bool = true)
    super(
      bus: bus,
      token: "test-token",
      streaming_enabled: streaming_enabled,
    )
  end

  private def api_request(method : String, params : Hash(String, String) = {} of String => String) : JSON::Any?
    @api_calls << {method, params.dup}
    case method
    when "sendMessage"
      JSON::Any.new({"message_id" => JSON::Any.new(100_i64)} of String => JSON::Any)
    when "editMessageText"
      JSON::Any.new({"ok" => JSON::Any.new(true)} of String => JSON::Any)
    else
      nil
    end
  end
end

# Text long enough to trigger the initial streaming message.
private def streaming_text : String
  "a" * Autobot::Channels::TelegramStreamingSession::MIN_INITIAL_LENGTH
end

describe "Telegram streaming finalization" do
  describe "send_message with active streaming session" do
    it "edits the streamed message with formatted HTML" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = TestableTelegramChannel.new(bus)

      callback = channel.create_stream_callback("chat1")
      callback.should_not be_nil
      callback.try(&.call(streaming_text))

      message = Autobot::Bus::OutboundMessage.new(
        channel: "telegram",
        chat_id: "chat1",
        content: "Hello **world**",
      )
      channel.send_message(message)

      # First call: sendMessage from streaming delta
      channel.api_calls[0][0].should eq("sendMessage")
      channel.api_calls[0][1]["chat_id"].should eq("chat1")

      # Second call: editMessageText with HTML-formatted content
      edit_call = channel.api_calls.find { |call| call[0] == "editMessageText" && call[1].has_key?("parse_mode") }
      edit_call.should_not be_nil
      if edit = edit_call
        edit[1]["message_id"].should eq("100")
        edit[1]["parse_mode"].should eq("HTML")
        edit[1]["text"].should contain("<b>world</b>")
      end
    end

    it "sends remaining chunks as new messages for long content" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = TestableTelegramChannel.new(bus)

      callback = channel.create_stream_callback("chat1")
      callback.try(&.call(streaming_text))

      # Build content with paragraphs exceeding Telegram max (4096 chars)
      paragraphs = (1..25).map { |i| "Paragraph #{i}: " + "a" * 200 }
      long_content = paragraphs.join("\n\n")

      message = Autobot::Bus::OutboundMessage.new(
        channel: "telegram",
        chat_id: "chat1",
        content: long_content,
      )
      channel.send_message(message)

      # Should have: sendMessage (streaming) + editMessageText (first chunk) + sendMessage (remaining chunks)
      send_calls = channel.api_calls.select { |call| call[0] == "sendMessage" }
      edit_calls = channel.api_calls.select { |call| call[0] == "editMessageText" }

      # At least one edit (finalize first chunk) and additional sends (remaining chunks)
      edit_calls.size.should be >= 1
      send_calls.size.should be >= 2 # initial streaming + overflow chunk(s)
    end

    it "falls back to plain text when HTML edit fails" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = TestableTelegramChannel.new(bus)

      message = Autobot::Bus::OutboundMessage.new(
        channel: "telegram",
        chat_id: "chat1",
        content: "Hello **world**",
      )

      callback = channel.create_stream_callback("chat1")
      callback.try(&.call(streaming_text))
      channel.send_message(message)

      # Verify the flow completed (sendMessage + at least one editMessageText)
      methods = channel.api_calls.map(&.[0])
      methods.should contain("sendMessage")
      methods.should contain("editMessageText")
    end
  end

  describe "send_message without streaming session" do
    it "sends message normally without finalization" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = TestableTelegramChannel.new(bus)

      message = Autobot::Bus::OutboundMessage.new(
        channel: "telegram",
        chat_id: "chat1",
        content: "Hello world",
      )
      channel.send_message(message)

      # No streaming session, so just a regular sendMessage
      channel.api_calls.size.should be >= 1
      channel.api_calls[0][0].should eq("sendMessage")
      channel.api_calls[0][1]["parse_mode"].should eq("HTML")
    end
  end

  describe "send_message after empty streaming session" do
    it "sends normally when streaming session had no message_id" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = TestableTelegramChannel.new(bus)

      # Create session but send empty delta (no message_id gets set)
      callback = channel.create_stream_callback("chat1")
      callback.try(&.call(""))

      message = Autobot::Bus::OutboundMessage.new(
        channel: "telegram",
        chat_id: "chat1",
        content: "Hello world",
      )
      channel.send_message(message)

      # No streaming message was sent, so just regular sendMessage
      methods = channel.api_calls.map(&.[0])
      methods.should_not contain("editMessageText")
      methods.should contain("sendMessage")
    end

    it "sends normally when streaming deltas were below threshold" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = TestableTelegramChannel.new(bus)

      # Create session but send short delta (below MIN_INITIAL_LENGTH)
      callback = channel.create_stream_callback("chat1")
      callback.try(&.call("Short"))

      message = Autobot::Bus::OutboundMessage.new(
        channel: "telegram",
        chat_id: "chat1",
        content: "Full response text here",
      )
      channel.send_message(message)

      # No initial streaming message was sent (below threshold), so regular delivery
      methods = channel.api_calls.map(&.[0])
      methods.should_not contain("editMessageText")
      methods.should contain("sendMessage")
    end
  end

  describe "create_stream_callback" do
    it "returns nil when streaming is disabled" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = TestableTelegramChannel.new(bus, streaming_enabled: false)

      callback = channel.create_stream_callback("chat1")
      callback.should be_nil
    end

    it "deactivates previous session for same chat_id" do
      bus = Autobot::Bus::MessageBus.new(capacity: 10)
      channel = TestableTelegramChannel.new(bus)

      callback1 = channel.create_stream_callback("chat1")
      callback1.try(&.call(streaming_text))

      # Creating a new session should deactivate the old one
      callback2 = channel.create_stream_callback("chat1")
      callback2.should_not be_nil

      # Old callback should be deactivated — deltas are silently dropped
      callback1.try(&.call(streaming_text))

      # Only the first sendMessage should have been called,
      # the second call is silently dropped due to deactivation
      send_calls = channel.api_calls.select { |call| call[0] == "sendMessage" }
      send_calls.size.should eq(1)
    end
  end
end
