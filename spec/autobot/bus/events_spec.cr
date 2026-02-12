require "../../spec_helper"

describe Autobot::Bus::InboundMessage do
  it "creates an inbound message" do
    msg = Autobot::Bus::InboundMessage.new(
      channel: "telegram",
      sender_id: "user123",
      chat_id: "456",
      content: "Hello bot"
    )

    msg.channel.should eq("telegram")
    msg.sender_id.should eq("user123")
    msg.chat_id.should eq("456")
    msg.content.should eq("Hello bot")
  end

  it "generates session key" do
    msg = Autobot::Bus::InboundMessage.new(
      channel: "telegram",
      sender_id: "user",
      chat_id: "789",
      content: "test"
    )
    msg.session_key.should eq("telegram:789")
  end

  it "serializes to JSON and back" do
    msg = Autobot::Bus::InboundMessage.new(
      channel: "slack",
      sender_id: "U123",
      chat_id: "C456",
      content: "test msg",
      metadata: {"thread_ts" => "123.456"}
    )

    json = msg.to_json
    parsed = Autobot::Bus::InboundMessage.from_json(json)
    parsed.channel.should eq("slack")
    parsed.content.should eq("test msg")
    parsed.metadata["thread_ts"].should eq("123.456")
  end

  it "supports media attachments" do
    media = Autobot::Bus::MediaAttachment.new(
      type: "photo",
      url: "https://example.com/photo.jpg",
      mime_type: "image/jpeg",
      size_bytes: 1024_i64
    )

    msg = Autobot::Bus::InboundMessage.new(
      channel: "telegram",
      sender_id: "user",
      chat_id: "123",
      content: "photo",
      media: [media]
    )

    media_items = msg.media?
    media_items.should_not be_nil
    media_items.try(&.size).should eq(1)
    media_items.try(&.first.type).should eq("photo")
  end
end

describe Autobot::Bus::OutboundMessage do
  it "creates an outbound message" do
    msg = Autobot::Bus::OutboundMessage.new(
      channel: "telegram",
      chat_id: "123",
      content: "Reply"
    )

    msg.channel.should eq("telegram")
    msg.chat_id.should eq("123")
    msg.content.should eq("Reply")
  end

  it "supports reply_to" do
    msg = Autobot::Bus::OutboundMessage.new(
      channel: "telegram",
      chat_id: "123",
      content: "Reply",
      reply_to: "msg_456"
    )

    msg.reply_to?.should eq("msg_456")
  end
end

describe Autobot::Bus::MediaAttachment do
  it "serializes to JSON" do
    media = Autobot::Bus::MediaAttachment.new(
      type: "document",
      file_path: "/tmp/doc.pdf",
      mime_type: "application/pdf"
    )

    json = media.to_json
    parsed = Autobot::Bus::MediaAttachment.from_json(json)
    parsed.type.should eq("document")
    parsed.file_path.should eq("/tmp/doc.pdf")
    parsed.mime_type.should eq("application/pdf")
  end
end
