require "../../spec_helper"

private class FakeTranscriber < Autobot::Transcriber
  getter calls = [] of String

  def initialize
    super(api_key: "test", provider: "openai")
  end

  def transcribe(audio_data : Bytes, filename : String = "voice.ogg") : String?
    @calls << filename
    "spoken words"
  end
end

private def fetcher(bytes : Bytes? = "audio-bytes".to_slice) : Autobot::Channels::TelegramMedia::Fetcher
  ->(_file_id : String) : Bytes? { bytes }
end

private def build_media(transcriber : Autobot::Transcriber? = nil, inbox : Autobot::Media::Inbox? = nil, bytes : Bytes? = "audio-bytes".to_slice) : Autobot::Channels::TelegramMedia
  Autobot::Channels::TelegramMedia.new(fetcher(bytes), transcriber, inbox)
end

private def with_inbox(&)
  dir = TestHelper.tmp_dir("inbox")
  yield Autobot::Media::Inbox.new(dir)
ensure
  FileUtils.rm_rf(dir) if dir
end

private def message(json : String) : JSON::Any
  JSON.parse(json)
end

private VOICE_NOTE = %({"voice": {"file_id": "v1", "mime_type": "audio/ogg", "duration": 7, "file_size": 512}})
private AUDIO_FILE = %({"audio": {"file_id": "a1", "mime_type": "audio/mp4", "title": "Car dealer", "duration": 134}})

describe Autobot::Channels::TelegramMedia do
  describe "a voice note recorded by the sender" do
    it "becomes the message text when nothing was typed" do
      transcriber = FakeTranscriber.new
      media = build_media(transcriber)

      parts, attachments = media.extract(message(VOICE_NOTE), typed_text: false)

      parts.should eq(["[voice transcription]: spoken words"])
      attachments.size.should eq(1)
      attachment = attachments.first
      attachment.sender_voice_note?.should be_true
      attachment.transcript.should be_nil
      attachment.transcribed?.should be_true
      attachment.duration_seconds.should eq(7)
      attachment.size_bytes.should eq(512)
      transcriber.calls.should eq(["audio.ogg"])
    end

    it "falls back to a placeholder without a transcriber" do
      media = build_media

      parts, attachments = media.extract(message(VOICE_NOTE), typed_text: false)

      parts.should eq(["[voice message]"])
      attachments.first.transcript.should be_nil
      attachments.first.transcribed?.should be_false
    end

    it "is content when typed text accompanies it" do
      media = build_media(FakeTranscriber.new)

      parts, attachments = media.extract(message(VOICE_NOTE), typed_text: true)

      parts.should be_empty
      attachments.first.sender_voice_note?.should be_true
      attachments.first.transcript.should eq("spoken words")
    end
  end

  describe "a forwarded voice note" do
    it "is content, with its transcript kept on the attachment" do
      media = build_media(FakeTranscriber.new)
      msg = message(%({"forward_origin": {"type": "user"}, "voice": {"file_id": "v2", "mime_type": "audio/ogg"}}))

      parts, attachments = media.extract(msg, typed_text: false)

      parts.should eq(["[voice message]"])
      attachment = attachments.first
      attachment.origin.should eq("forwarded")
      attachment.sender_voice_note?.should be_false
      attachment.transcript.should eq("spoken words")
    end

    it "recognizes the legacy forward fields" do
      media = build_media
      media.forwarded?(message(%({"forward_date": 1, "text": "hi"}))).should be_true
      media.forwarded?(message(%({"forward_sender_name": "Someone", "text": "hi"}))).should be_true
      media.forwarded?(message(%({"text": "hi"}))).should be_false
    end
  end

  describe "an audio file" do
    it "is content with its transcript on the attachment, never in the text" do
      transcriber = FakeTranscriber.new
      media = build_media(transcriber)

      parts, attachments = media.extract(message(AUDIO_FILE), typed_text: false)

      parts.should eq(["[audio: Car dealer]"])
      attachment = attachments.first
      attachment.type.should eq("audio")
      attachment.sender_voice_note?.should be_false
      attachment.transcript.should eq("spoken words")
      attachment.name.should eq("Car dealer")
      attachment.duration_seconds.should eq(134)
      transcriber.calls.should eq(["audio.m4a"])
    end

    it "takes the format from the file name when the platform sends no mime type" do
      transcriber = FakeTranscriber.new
      media = build_media(transcriber)
      msg = message(%({"audio": {"file_id": "a2", "file_name": "New Recording 6.m4a"}}))

      _, attachments = media.extract(msg, typed_text: false)

      attachments.first.mime_type.should eq("audio/mp4")
      attachments.first.name.should eq("New Recording 6.m4a")
      transcriber.calls.should eq(["audio.m4a"])
    end

    it "prefers the file name extension over a conflicting mime type" do
      transcriber = FakeTranscriber.new
      msg = message(%({"audio": {"file_id": "a3", "file_name": "memo.m4a", "mime_type": "audio/mpeg"}}))

      build_media(transcriber).extract(msg, typed_text: false)

      transcriber.calls.should eq(["audio.m4a"])
    end

    it "adds no text when a caption was typed" do
      media = build_media(FakeTranscriber.new)

      parts, attachments = media.extract(message(AUDIO_FILE), typed_text: true)

      parts.should be_empty
      attachments.first.transcript.should eq("spoken words")
    end
  end

  describe "photos and documents" do
    it "keeps photo bytes for vision and labels the message" do
      media = build_media(bytes: "img".to_slice)
      msg = message(%({"photo": [{"file_id": "small"}, {"file_id": "large", "file_size": 3}]}))

      parts, attachments = media.extract(msg, typed_text: false)

      parts.should eq(["[photo]"])
      attachment = attachments.first
      attachment.url.should eq("large")
      attachment.data.should eq(Base64.strict_encode("img"))
      attachment.mime_type.should eq("image/jpeg")
    end

    it "labels documents by file name" do
      media = build_media
      msg = message(%({"document": {"file_id": "d1", "file_name": "report.pdf", "mime_type": "application/pdf"}}))

      parts, attachments = media.extract(msg, typed_text: false)

      parts.should eq(["[document: report.pdf]"])
      attachments.first.name.should eq("report.pdf")
      attachments.first.mime_type.should eq("application/pdf")
    end

    it "returns nothing for a plain text message" do
      media = build_media
      parts, attachments = media.extract(message(%({"text": "hello"})), typed_text: true)
      parts.should be_empty
      attachments.should be_empty
    end
  end

  describe "with an inbox" do
    it "saves the media and the transcript and records their paths" do
      with_inbox do |inbox|
        _, attachments = build_media(FakeTranscriber.new, inbox).extract(message(AUDIO_FILE), typed_text: true)

        attachment = attachments.first
        file_path = attachment.file_path.to_s
        File.read(file_path).should eq("audio-bytes")
        file_path.should end_with(".m4a")
        File.read(attachment.transcript_path.to_s).should eq("spoken words")
      end
    end

    it "saves a spoken voice note without a transcript file" do
      with_inbox do |inbox|
        _, attachments = build_media(FakeTranscriber.new, inbox).extract(message(VOICE_NOTE), typed_text: false)

        attachments.first.file_path.to_s.should end_with(".ogg")
        attachments.first.transcript_path.should be_nil
      end
    end

    it "names the saved file after the platform file name's extension" do
      with_inbox do |inbox|
        msg = message(%({"audio": {"file_id": "a2", "file_name": "New Recording 6.m4a"}}))
        _, attachments = build_media(nil, inbox).extract(msg, typed_text: false)
        attachments.first.file_path.to_s.should end_with(".m4a")
      end
    end

    it "records no path when the download failed" do
      media = build_media(FakeTranscriber.new, Autobot::Media::Inbox.new(Path["/nonexistent"]), bytes: nil)

      parts, attachments = media.extract(message(VOICE_NOTE), typed_text: false)

      parts.should eq(["[voice message]"])
      attachments.first.file_path.should be_nil
    end
  end
end
