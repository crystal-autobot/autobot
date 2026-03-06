require "../../spec_helper"

describe Autobot::Tools::MessageTool do
  it "has correct name" do
    tool = Autobot::Tools::MessageTool.new
    tool.name.should eq("message")
  end

  it "has file_path in parameters" do
    tool = Autobot::Tools::MessageTool.new
    schema = tool.parameters
    schema.properties.has_key?("file_path").should be_true
  end

  it "sends text message without file" do
    sent_messages = [] of Autobot::Bus::OutboundMessage
    tool = Autobot::Tools::MessageTool.new
    tool.set_context("telegram", "123")
    tool.send_callback = ->(msg : Autobot::Bus::OutboundMessage) { sent_messages << msg; nil }

    result = tool.execute({"content" => JSON::Any.new("hello")})
    result.success?.should be_true

    sent_messages.size.should eq(1)
    sent_messages[0].content.should eq("hello")
    sent_messages[0].media?.should be_nil
  end

  it "returns error when no channel context" do
    tool = Autobot::Tools::MessageTool.new
    tool.send_callback = ->(_msg : Autobot::Bus::OutboundMessage) { nil }

    result = tool.execute({"content" => JSON::Any.new("hello")})
    result.success?.should be_false
    result.content.should contain("No target channel/chat")
  end

  it "returns error when send callback not configured" do
    tool = Autobot::Tools::MessageTool.new
    tool.set_context("telegram", "123")

    result = tool.execute({"content" => JSON::Any.new("hello")})
    result.success?.should be_false
    result.content.should contain("not configured")
  end

  it "returns error when file_path given but no executor" do
    sent_messages = [] of Autobot::Bus::OutboundMessage
    tool = Autobot::Tools::MessageTool.new
    tool.set_context("telegram", "123")
    tool.send_callback = ->(msg : Autobot::Bus::OutboundMessage) { sent_messages << msg; nil }

    result = tool.execute({
      "content"   => JSON::Any.new("here's the file"),
      "file_path" => JSON::Any.new("test.gif"),
    })
    result.success?.should be_false
    result.content.should contain("not available")
  end

  it "sends message with file attachment" do
    tmp = TestHelper.tmp_dir
    File.write((tmp / "test.gif").to_s, "GIF89a fake gif data")

    executor = Autobot::Tools::SandboxExecutor.new(nil)
    sent_messages = [] of Autobot::Bus::OutboundMessage
    tool = Autobot::Tools::MessageTool.new(executor: executor)
    tool.set_context("telegram", "123")
    tool.send_callback = ->(msg : Autobot::Bus::OutboundMessage) { sent_messages << msg; nil }

    result = tool.execute({
      "content"   => JSON::Any.new("here's your GIF"),
      "file_path" => JSON::Any.new((tmp / "test.gif").to_s),
    })
    result.success?.should be_true

    sent_messages.size.should eq(1)
    msg = sent_messages[0]
    msg.content.should eq("here's your GIF")
    msg.media?.should_not be_nil

    media = msg.media?.as(Array(Autobot::Bus::MediaAttachment))
    media.size.should eq(1)
    media[0].type.should eq("animation")
    media[0].mime_type.should eq("image/gif")
    media[0].data.should_not be_nil
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "detects photo type from extension" do
    tmp = TestHelper.tmp_dir
    File.write((tmp / "photo.png").to_s, "fake png data")

    executor = Autobot::Tools::SandboxExecutor.new(nil)
    sent_messages = [] of Autobot::Bus::OutboundMessage
    tool = Autobot::Tools::MessageTool.new(executor: executor)
    tool.set_context("telegram", "123")
    tool.send_callback = ->(msg : Autobot::Bus::OutboundMessage) { sent_messages << msg; nil }

    result = tool.execute({
      "content"   => JSON::Any.new("a photo"),
      "file_path" => JSON::Any.new((tmp / "photo.png").to_s),
    })
    result.success?.should be_true

    media = sent_messages[0].media?.as(Array(Autobot::Bus::MediaAttachment))
    media[0].type.should eq("photo")
    media[0].mime_type.should eq("image/png")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "falls back to document type for unknown extensions" do
    tmp = TestHelper.tmp_dir
    File.write((tmp / "data.csv").to_s, "a,b,c\n1,2,3")

    executor = Autobot::Tools::SandboxExecutor.new(nil)
    sent_messages = [] of Autobot::Bus::OutboundMessage
    tool = Autobot::Tools::MessageTool.new(executor: executor)
    tool.set_context("telegram", "123")
    tool.send_callback = ->(msg : Autobot::Bus::OutboundMessage) { sent_messages << msg; nil }

    result = tool.execute({
      "content"   => JSON::Any.new("some data"),
      "file_path" => JSON::Any.new((tmp / "data.csv").to_s),
    })
    result.success?.should be_true

    media = sent_messages[0].media?.as(Array(Autobot::Bus::MediaAttachment))
    media[0].type.should eq("document")
    media[0].mime_type.should eq("application/octet-stream")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns error when file not found" do
    executor = Autobot::Tools::SandboxExecutor.new(nil)
    sent_messages = [] of Autobot::Bus::OutboundMessage
    tool = Autobot::Tools::MessageTool.new(executor: executor)
    tool.set_context("telegram", "123")
    tool.send_callback = ->(msg : Autobot::Bus::OutboundMessage) { sent_messages << msg; nil }

    result = tool.execute({
      "content"   => JSON::Any.new("file"),
      "file_path" => JSON::Any.new("/nonexistent/file.gif"),
    })
    result.success?.should be_false
    result.content.should contain("Cannot read file")
  end

  describe "#last_sent_content" do
    it "is nil before any message is sent" do
      tool = Autobot::Tools::MessageTool.new
      tool.last_sent_content.should be_nil
    end

    it "captures content after successful send" do
      tool = Autobot::Tools::MessageTool.new
      tool.set_context("telegram", "123")
      tool.send_callback = ->(_msg : Autobot::Bus::OutboundMessage) { nil }

      tool.execute({"content" => JSON::Any.new("weather report")})
      tool.last_sent_content.should eq("weather report")
    end

    it "does not capture content on send failure" do
      tool = Autobot::Tools::MessageTool.new
      # No callback configured → will fail
      tool.set_context("telegram", "123")

      tool.execute({"content" => JSON::Any.new("will fail")})
      tool.last_sent_content.should be_nil
    end

    it "is cleared by clear_last_sent" do
      tool = Autobot::Tools::MessageTool.new
      tool.set_context("telegram", "123")
      tool.send_callback = ->(_msg : Autobot::Bus::OutboundMessage) { nil }

      tool.execute({"content" => JSON::Any.new("first message")})
      tool.last_sent_content.should eq("first message")

      tool.clear_last_sent
      tool.last_sent_content.should be_nil
    end
  end
end
