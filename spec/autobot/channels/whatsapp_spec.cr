require "../../spec_helper"

# Expose private methods for testing via a thin subclass.
class WhatsAppChannelTest < Autobot::Channels::WhatsAppChannel
  def test_extract_reply_context(data : JSON::Any) : String?
    extract_reply_context(data)
  end

  def test_resolve_sender_id(data : JSON::Any, sender : String) : String
    resolve_sender_id(data, sender)
  end

  def test_build_content(data : JSON::Any, sender_id : String) : String
    build_content(data, sender_id)
  end

  def test_build_metadata(data : JSON::Any) : Hash(String, String)
    build_metadata(data)
  end
end

private def build_whatsapp_channel(
  allow_from : Array(String) = ["*"],
) : WhatsAppChannelTest
  bus = Autobot::Bus::MessageBus.new
  WhatsAppChannelTest.new(
    bus: bus,
    bridge_url: "ws://localhost:3001",
    allow_from: allow_from,
  )
end

describe Autobot::Channels::WhatsAppChannel do
  describe "#extract_reply_context" do
    it "returns nil when no quoted field" do
      data = JSON.parse(%({"content": "hello"}))
      channel = build_whatsapp_channel
      channel.test_extract_reply_context(data).should be_nil
    end

    it "returns empty string when quoted is empty" do
      data = JSON.parse(%({"content": "hello", "quoted": ""}))
      channel = build_whatsapp_channel
      channel.test_extract_reply_context(data).should eq("")
    end

    it "extracts quoted text" do
      data = JSON.parse(%({"content": "yes", "quoted": "Do you want to proceed?"}))
      channel = build_whatsapp_channel
      channel.test_extract_reply_context(data).should eq("Do you want to proceed?")
    end

    it "returns full text without truncation" do
      long_text = "a" * 600
      data = JSON.parse(%({"content": "ok", "quoted": "#{long_text}"}))
      channel = build_whatsapp_channel
      channel.test_extract_reply_context(data).should eq(long_text)
    end
  end

  describe "#resolve_sender_id" do
    it "uses pn when available" do
      data = JSON.parse(%({"pn": "1234567890@s.whatsapp.net"}))
      channel = build_whatsapp_channel
      channel.test_resolve_sender_id(data, "sender@s.whatsapp.net").should eq("1234567890")
    end

    it "falls back to sender when pn is empty" do
      data = JSON.parse(%({"pn": ""}))
      channel = build_whatsapp_channel
      channel.test_resolve_sender_id(data, "1234567890@s.whatsapp.net").should eq("1234567890")
    end

    it "falls back to sender when pn is missing" do
      data = JSON.parse(%({}))
      channel = build_whatsapp_channel
      channel.test_resolve_sender_id(data, "1234567890@s.whatsapp.net").should eq("1234567890")
    end

    it "returns sender as-is when no @ present" do
      data = JSON.parse(%({}))
      channel = build_whatsapp_channel
      channel.test_resolve_sender_id(data, "1234567890").should eq("1234567890")
    end
  end

  describe "#build_content" do
    it "returns plain text content" do
      data = JSON.parse(%({"content": "hello world"}))
      channel = build_whatsapp_channel
      channel.test_build_content(data, "user1").should eq("hello world")
    end

    it "replaces voice message placeholder" do
      data = JSON.parse(%({"content": "[Voice Message]"}))
      channel = build_whatsapp_channel
      channel.test_build_content(data, "user1").should contain("Transcription not available")
    end

    it "prepends reply context when quoted is present" do
      data = JSON.parse(%({"content": "yes please", "quoted": "Should I continue?"}))
      channel = build_whatsapp_channel
      result = channel.test_build_content(data, "user1")
      result.should contain("[Replying to: \"Should I continue?\"]")
      result.should contain("yes please")
    end

    it "returns empty string when content is missing" do
      data = JSON.parse(%({}))
      channel = build_whatsapp_channel
      channel.test_build_content(data, "user1").should eq("")
    end
  end

  describe "#build_metadata" do
    it "extracts metadata from data" do
      data = JSON.parse(%({"id": "msg123", "timestamp": "1234567890", "isGroup": true}))
      channel = build_whatsapp_channel
      meta = channel.test_build_metadata(data)
      meta["message_id"].should eq("msg123")
      meta["timestamp"].should eq("1234567890")
      meta["is_group"].should eq("true")
    end

    it "handles missing fields with defaults" do
      data = JSON.parse(%({}))
      channel = build_whatsapp_channel
      meta = channel.test_build_metadata(data)
      meta["message_id"].should eq("")
      meta["timestamp"].should eq("")
      meta["is_group"].should eq("false")
    end
  end

  describe "#allowed?" do
    it "denies all when allow_from is empty" do
      channel = build_whatsapp_channel(allow_from: [] of String)
      channel.allowed?("1234567890").should be_false
    end

    it "allows all with wildcard" do
      channel = build_whatsapp_channel(allow_from: ["*"])
      channel.allowed?("1234567890").should be_true
    end

    it "allows specific user" do
      channel = build_whatsapp_channel(allow_from: ["1234567890"])
      channel.allowed?("1234567890").should be_true
      channel.allowed?("9999999999").should be_false
    end
  end
end
