require "../../spec_helper"

# Expose private methods for testing via a thin subclass.
class SlackChannelTest < Autobot::Channels::SlackChannel
  def test_slack_allowed?(sender_id : String, chat_id : String, channel_type : String) : Bool
    slack_allowed?(sender_id, chat_id, channel_type)
  end

  def test_should_respond_in_channel?(event_type : String, text : String, chat_id : String) : Bool
    should_respond_in_channel?(event_type, text, chat_id)
  end

  def test_strip_bot_mention(text : String) : String
    strip_bot_mention(text)
  end
end

private def build_slack_channel(
  allow_from : Array(String) = ["*"],
  group_policy : String = "mention",
  group_allow_from : Array(String) = [] of String,
  dm_enabled : Bool = false,
  dm_policy : String = "allowlist",
  dm_allow_from : Array(String) = [] of String,
) : SlackChannelTest
  bus = Autobot::Bus::MessageBus.new
  dm_config = Autobot::Config::SlackDMConfig.from_yaml(
    {enabled: dm_enabled, policy: dm_policy, allow_from: dm_allow_from}.to_yaml
  )
  SlackChannelTest.new(
    bus: bus,
    bot_token: "xoxb-test",
    app_token: "xapp-test",
    allow_from: allow_from,
    group_policy: group_policy,
    group_allow_from: group_allow_from,
    dm_config: dm_config,
  )
end

describe Autobot::Channels::SlackChannel do
  describe "base class allow_from" do
    it "denies all senders when allow_from is empty" do
      channel = build_slack_channel(allow_from: [] of String)
      channel.allowed?("U12345").should be_false
    end

    it "allows all senders with wildcard" do
      channel = build_slack_channel(allow_from: ["*"])
      channel.allowed?("U12345").should be_true
    end

    it "allows specific sender by ID" do
      channel = build_slack_channel(allow_from: ["U12345"])
      channel.allowed?("U12345").should be_true
      channel.allowed?("U99999").should be_false
    end
  end

  describe "#slack_allowed?" do
    context "DM messages" do
      it "denies DMs when disabled" do
        channel = build_slack_channel(dm_enabled: false)
        channel.test_slack_allowed?("U12345", "D123", "im").should be_false
      end

      it "allows DMs from anyone with open policy" do
        channel = build_slack_channel(dm_enabled: true, dm_policy: "open")
        channel.test_slack_allowed?("U12345", "D123", "im").should be_true
        channel.test_slack_allowed?("U99999", "D456", "im").should be_true
      end

      it "allows DMs only from allowlist with allowlist policy" do
        channel = build_slack_channel(
          dm_enabled: true, dm_policy: "allowlist", dm_allow_from: ["U12345"]
        )
        channel.test_slack_allowed?("U12345", "D123", "im").should be_true
        channel.test_slack_allowed?("U99999", "D456", "im").should be_false
      end
    end

    context "channel messages" do
      it "allows channel messages by default" do
        channel = build_slack_channel(group_policy: "mention")
        channel.test_slack_allowed?("U12345", "C123", "channel").should be_true
      end

      it "allows only allowlisted channels with allowlist policy" do
        channel = build_slack_channel(
          group_policy: "allowlist", group_allow_from: ["C123"]
        )
        channel.test_slack_allowed?("U12345", "C123", "channel").should be_true
        channel.test_slack_allowed?("U12345", "C999", "channel").should be_false
      end
    end
  end

  describe "#should_respond_in_channel?" do
    it "responds to all messages with open policy" do
      channel = build_slack_channel(group_policy: "open")
      channel.test_should_respond_in_channel?("message", "hello", "C123").should be_true
    end

    it "responds only to app_mention with mention policy" do
      channel = build_slack_channel(group_policy: "mention")
      channel.test_should_respond_in_channel?("app_mention", "hello", "C123").should be_true
      channel.test_should_respond_in_channel?("message", "hello", "C123").should be_false
    end

    it "responds only in allowlisted channels with allowlist policy" do
      channel = build_slack_channel(
        group_policy: "allowlist", group_allow_from: ["C123"]
      )
      channel.test_should_respond_in_channel?("message", "hello", "C123").should be_true
      channel.test_should_respond_in_channel?("message", "hello", "C999").should be_false
    end

    it "denies all with unknown policy" do
      channel = build_slack_channel(group_policy: "unknown")
      channel.test_should_respond_in_channel?("message", "hello", "C123").should be_false
    end
  end

  describe "#strip_bot_mention" do
    it "returns text unchanged when no bot ID" do
      channel = build_slack_channel
      channel.test_strip_bot_mention("hello world").should eq("hello world")
    end
  end
end

describe Autobot::Config::SlackConfig do
  it "deserializes with allow_from" do
    yaml = <<-YAML
    enabled: true
    bot_token: "xoxb-test"
    app_token: "xapp-test"
    allow_from: ["U12345", "U67890"]
    group_policy: "mention"
    YAML

    config = Autobot::Config::SlackConfig.from_yaml(yaml)
    config.enabled?.should be_true
    config.allow_from.should eq(["U12345", "U67890"])
  end

  it "defaults allow_from to empty array" do
    yaml = <<-YAML
    enabled: true
    bot_token: "xoxb-test"
    app_token: "xapp-test"
    YAML

    config = Autobot::Config::SlackConfig.from_yaml(yaml)
    config.allow_from.should be_empty
  end
end

describe Autobot::Config::ConfigValidator do
  it "warns when Slack allow_from is empty" do
    config_yaml = <<-YAML
    providers:
      anthropic:
        api_key: "test-key"
    channels:
      slack:
        enabled: true
        bot_token: "xoxb-test"
        allow_from: []
    YAML

    config = Autobot::Config::Config.from_yaml(config_yaml)
    issues = Autobot::Config::ConfigValidator.validate(config)

    warnings = issues.select { |i| i.severity == Autobot::Config::ValidatorCommon::Severity::Warning }
    warnings.any?(&.message.includes?("allow_from is empty")).should be_true
  end
end
