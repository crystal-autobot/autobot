require "../../spec_helper"

private def inbound(content : String, media : Array(Autobot::Bus::MediaAttachment)?) : Autobot::Bus::InboundMessage
  Autobot::Bus::InboundMessage.new(channel: "telegram", sender_id: "u1", chat_id: "c1", content: content, media: media)
end

describe Autobot::Bus::InboundMessage do
  it "knows a sender voice note nobody transcribed" do
    unheard = Autobot::Bus::MediaAttachment.new(type: "voice")
    heard = Autobot::Bus::MediaAttachment.new(type: "voice", transcribed: true)
    forwarded = Autobot::Bus::MediaAttachment.new(type: "voice", origin: "forwarded")

    inbound("[voice message]", [unheard]).unheard_voice_note?.should be_true
    inbound("[voice transcription]: hi", [heard]).unheard_voice_note?.should be_false
    inbound("[voice message]", [forwarded]).unheard_voice_note?.should be_false
    inbound("hi", nil).unheard_voice_note?.should be_false
  end

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

  it "excludes data field from JSON serialization" do
    media = Autobot::Bus::MediaAttachment.new(
      type: "photo",
      url: "file_id_123",
      mime_type: "image/jpeg",
      data: "base64encodeddata"
    )

    media.data.should eq("base64encodeddata")

    json = media.to_json
    json.should_not contain("data")
    json.should_not contain("base64encodeddata")

    parsed = Autobot::Bus::MediaAttachment.from_json(json)
    parsed.data.should be_nil
    parsed.type.should eq("photo")
    parsed.url.should eq("file_id_123")
  end

  it "defaults data to nil" do
    media = Autobot::Bus::MediaAttachment.new(type: "photo")
    media.data.should be_nil
  end

  it "defaults to the sender origin" do
    Autobot::Bus::MediaAttachment.new(type: "voice").origin.should eq("sender")
  end

  it "recognizes only a sender's voice note" do
    Autobot::Bus::MediaAttachment.new(type: "voice").sender_voice_note?.should be_true
    Autobot::Bus::MediaAttachment.new(type: "voice", origin: "forwarded").sender_voice_note?.should be_false
    Autobot::Bus::MediaAttachment.new(type: "audio").sender_voice_note?.should be_false
    Autobot::Bus::MediaAttachment.new(type: "document").sender_voice_note?.should be_false
  end

  it "round-trips attachment details through JSON" do
    media = Autobot::Bus::MediaAttachment.new(
      type: "audio",
      file_path: "/inbox/memo.m4a",
      origin: "forwarded",
      transcript: "spoken words",
      transcript_path: "/inbox/memo.txt",
      duration_seconds: 134,
      name: "Car dealer"
    )

    parsed = Autobot::Bus::MediaAttachment.from_json(media.to_json)
    parsed.origin.should eq("forwarded")
    parsed.transcript.should eq("spoken words")
    parsed.transcribed?.should be_true
    parsed.transcript_path.should eq("/inbox/memo.txt")
    parsed.duration_seconds.should eq(134)
    parsed.name.should eq("Car dealer")
  end

  it "parses attachments written before origin existed" do
    parsed = Autobot::Bus::MediaAttachment.from_json(%({"type": "photo", "url": "f1"}))
    parsed.origin.should eq("sender")
    parsed.transcribed?.should be_false
  end
end
