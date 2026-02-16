require "../../spec_helper"

# Expose private methods for testing via a thin subclass.
class TelegramChannelTest < Autobot::Channels::TelegramChannel
  def test_access_denied_message(sender_id : String) : String
    access_denied_message(sender_id)
  end

  def test_command_description(entry : Autobot::Config::CustomCommandEntry, name : String) : String
    command_description(entry, name)
  end
end

private def build_channel(allow_from : Array(String) = [] of String, custom_commands : Autobot::Config::CustomCommandsConfig? = nil) : TelegramChannelTest
  bus = Autobot::Bus::MessageBus.new
  cmds = custom_commands || Autobot::Config::CustomCommandsConfig.new
  TelegramChannelTest.new(
    bus: bus,
    token: "test-token",
    allow_from: allow_from,
    custom_commands: cmds,
  )
end

describe Autobot::Channels::TelegramChannel do
  describe "#access_denied_message" do
    it "shows setup instructions when allow_from is empty" do
      channel = build_channel(allow_from: [] of String)
      msg = channel.test_access_denied_message("12345|johndoe")

      msg.should contain("no authorized users yet")
      msg.should contain("allow_from")
      msg.should contain("config.yml")
      msg.should contain("12345|johndoe")
    end

    it "escapes HTML in sender ID" do
      channel = build_channel(allow_from: [] of String)
      msg = channel.test_access_denied_message("<script>alert(1)</script>")

      msg.should_not contain("<script>")
      msg.should contain("&lt;script&gt;")
    end

    it "shows generic denial when allow_from has users" do
      channel = build_channel(allow_from: ["allowed_user"])
      msg = channel.test_access_denied_message("other_user")

      msg.should contain("Access denied")
      msg.should contain("not in the authorized users list")
      msg.should_not contain("config.yml")
    end
  end

  describe "#command_description" do
    it "returns description when provided" do
      entry = Autobot::Config::CustomCommandEntry.new("prompt text", "My description")
      channel = build_channel
      channel.test_command_description(entry, "cmd").should eq("My description")
    end

    it "humanizes command name when no description" do
      entry = Autobot::Config::CustomCommandEntry.new("prompt text")
      channel = build_channel
      channel.test_command_description(entry, "check_status").should eq("Check status")
    end

    it "humanizes command name with hyphens" do
      entry = Autobot::Config::CustomCommandEntry.new("prompt text")
      channel = build_channel
      channel.test_command_description(entry, "run-deploy").should eq("Run deploy")
    end
  end
end
