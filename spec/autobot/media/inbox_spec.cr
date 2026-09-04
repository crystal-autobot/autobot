require "../../spec_helper"

private def with_inbox(&)
  dir = TestHelper.tmp_dir("inbox")
  yield Autobot::Media::Inbox.new(dir), dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Autobot::Media::Inbox do
  describe "#store" do
    it "writes the bytes with an extension from the mime type and private permissions" do
      with_inbox do |inbox, dir|
        path = inbox.store("hello".to_slice, "audio/ogg")

        path.parent.should eq(dir)
        path.extension.should eq(".ogg")
        File.read(path).should eq("hello")
        File.info(path).permissions.value.should eq(0o600)
      end
    end

    it "creates the directory with private permissions" do
      dir = TestHelper.tmp_dir("inbox")
      begin
        Autobot::Media::Inbox.new(dir / "inbox").store("x".to_slice, "image/png")
        File.info(dir / "inbox").permissions.value.should eq(0o700)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "falls back to the given extension for unknown mime types" do
      with_inbox do |inbox, _|
        inbox.store("x".to_slice, "application/x-unknown", ".voice").extension.should eq(".voice")
        inbox.store("x".to_slice, nil).extension.should eq(".bin")
      end
    end

    it "gives every file a distinct name" do
      with_inbox do |inbox, _|
        inbox.store("a".to_slice, "image/jpeg").should_not eq(inbox.store("b".to_slice, "image/jpeg"))
      end
    end
  end

  describe "#store_transcript" do
    it "writes the transcript next to the media file" do
      with_inbox do |inbox, dir|
        media = inbox.store("x".to_slice, "audio/mpeg")
        transcript = inbox.store_transcript("spoken words", media)

        transcript.should eq(dir / "#{media.stem}.txt")
        File.read(transcript).should eq("spoken words")
      end
    end
  end
end
