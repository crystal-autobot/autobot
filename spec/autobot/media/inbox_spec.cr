require "../../spec_helper"

describe Autobot::Media::Inbox do
  describe "#store" do
    it "writes the bytes under the inbox with an extension from the mime type" do
      dir = TestHelper.tmp_dir("inbox")
      begin
        inbox = Autobot::Media::Inbox.new(dir / "inbox")
        path = inbox.store("hello".to_slice, "audio/ogg")

        path.parent.should eq(dir / "inbox")
        path.extension.should eq(".ogg")
        File.read(path).should eq("hello")
        File.info(path).permissions.value.should eq(0o600)
        File.info(dir / "inbox").permissions.value.should eq(0o700)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "falls back to the given extension for unknown mime types" do
      dir = TestHelper.tmp_dir("inbox")
      begin
        inbox = Autobot::Media::Inbox.new(dir)
        inbox.store("x".to_slice, "application/x-unknown", "voice").extension.should eq(".voice")
        inbox.store("x".to_slice, nil, "bin").extension.should eq(".bin")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "gives every file a distinct name" do
      dir = TestHelper.tmp_dir("inbox")
      begin
        inbox = Autobot::Media::Inbox.new(dir)
        first = inbox.store("a".to_slice, "image/jpeg")
        second = inbox.store("b".to_slice, "image/jpeg")
        first.should_not eq(second)
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "#store_transcript" do
    it "writes the transcript next to the media file" do
      dir = TestHelper.tmp_dir("inbox")
      begin
        inbox = Autobot::Media::Inbox.new(dir)
        media = inbox.store("x".to_slice, "audio/mpeg")
        transcript = inbox.store_transcript("spoken words", media)

        transcript.should eq(dir / "#{media.stem}.txt")
        File.read(transcript).should eq("spoken words")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe ".extension_for" do
    it "ignores mime parameters and case" do
      Autobot::Media::Inbox.extension_for("Audio/OGG; codecs=opus", "bin").should eq("ogg")
    end
  end
end
