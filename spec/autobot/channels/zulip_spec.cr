require "../../spec_helper"

# Expose private methods for testing via a thin subclass.
class ZulipChannelTest < Autobot::Channels::ZulipChannel
  def test_access_denied_message(sender_id : String) : String
    access_denied_message(sender_id)
  end

  def test_process_event(event : JSON::Any)
    process_event(event)
  end
end

private def build_channel(
  allow_from : Array(String) = [] of String,
) : ZulipChannelTest
  bus = Autobot::Bus::MessageBus.new
  ZulipChannelTest.new(
    bus: bus,
    site: "https://zulip.example.com",
    email: "bot@example.com",
    api_key: "test-api-key",
    allow_from: allow_from,
  )
end

describe Autobot::Channels::ZulipChannel do
  describe "#access_denied_message" do
    it "shows setup instructions when allow_from is empty" do
      channel = build_channel(allow_from: [] of String)
      msg = channel.test_access_denied_message("user@example.com")

      msg.should contain("no authorized users yet")
      msg.should contain("allow_from")
      msg.should contain("config.yml")
      msg.should contain("user@example.com")
    end

    it "shows generic denial when allow_from has entries" do
      channel = build_channel(allow_from: ["allowed@example.com"])
      msg = channel.test_access_denied_message("other@example.com")

      msg.should contain("Access denied")
      msg.should contain("not in the authorized users list")
      msg.should_not contain("config.yml")
    end

    it "uses Markdown backticks instead of HTML code tags" do
      channel = build_channel(allow_from: [] of String)
      msg = channel.test_access_denied_message("user@example.com")

      msg.should contain("`allow_from`")
      msg.should contain("`user@example.com`")
      msg.should_not contain("<code>")
      msg.should_not contain("</code>")
    end
  end

  describe "#allowed?" do
    it "denies when allow_from is empty" do
      channel = build_channel(allow_from: [] of String)
      channel.allowed?("user@example.com").should be_false
    end

    it "allows matching email" do
      channel = build_channel(allow_from: ["user@example.com"])
      channel.allowed?("user@example.com").should be_true
    end

    it "allows wildcard *" do
      channel = build_channel(allow_from: ["*"])
      channel.allowed?("anyone@example.com").should be_true
    end

    it "denies non-matching email" do
      channel = build_channel(allow_from: ["allowed@example.com"])
      channel.allowed?("other@example.com").should be_false
    end
  end
end
