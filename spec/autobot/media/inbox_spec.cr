require "../../spec_helper"

private def with_inbox(&)
  dir = TestHelper.tmp_dir("inbox")
  yield Autobot::Media::Inbox.new(dir), dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Autobot::Media::Inbox do
  describe "#store" do
    it "writes the bytes with the given extension and private permissions" do
      with_inbox do |inbox, dir|
        path = inbox.store("hello".to_slice, ".ogg")

        path.parent.should eq(dir)
        path.extension.should eq(".ogg")
        File.read(path).should eq("hello")
        File.info(path).permissions.value.should eq(0o600)
      end
    end

    it "creates the directory with private permissions" do
      dir = TestHelper.tmp_dir("inbox")
      begin
        Autobot::Media::Inbox.new(dir / "inbox").store("x".to_slice, ".png")
        File.info(dir / "inbox").permissions.value.should eq(0o700)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "gives every file a distinct name" do
      with_inbox do |inbox, _|
        inbox.store("a".to_slice, ".jpg").should_not eq(inbox.store("b".to_slice, ".jpg"))
      end
    end
  end

  describe "#store_transcript" do
    it "writes the transcript next to the media file" do
      with_inbox do |inbox, dir|
        media = inbox.store("x".to_slice, ".mp3")
        transcript = inbox.store_transcript("spoken words", media)

        transcript.should eq(dir / "#{media.stem}.txt")
        File.read(transcript).should eq("spoken words")
      end
    end
  end
end
