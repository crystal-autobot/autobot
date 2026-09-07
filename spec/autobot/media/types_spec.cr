require "../../spec_helper"

describe Autobot::Media::Types do
  describe ".for_extension" do
    it "maps known extensions to a media type and mime" do
      Autobot::Media::Types.for_extension(".M4A").should eq({"audio", "audio/mp4"})
      Autobot::Media::Types.for_extension(".ogg").should eq({"voice", "audio/ogg"})
    end

    it "falls back to a generic document" do
      Autobot::Media::Types.for_extension(".xyz").should eq({"document", "application/octet-stream"})
    end
  end

  describe ".audio?" do
    it "recognises audio mime types, parameters and case included" do
      Autobot::Media::Types.audio?("audio/mp4").should be_true
      Autobot::Media::Types.audio?("Audio/OGG; codecs=opus").should be_true
      Autobot::Media::Types.audio?("audio/x-m4a").should be_true
    end

    it "rejects everything else" do
      Autobot::Media::Types.audio?("application/pdf").should be_false
      Autobot::Media::Types.audio?(nil).should be_false
    end
  end

  describe ".image?" do
    it "recognises image mime types and rejects the rest" do
      Autobot::Media::Types.image?("image/png").should be_true
      Autobot::Media::Types.image?("audio/mp4").should be_false
      Autobot::Media::Types.image?(nil).should be_false
    end
  end

  describe ".extension_for" do
    it "ignores mime parameters and case" do
      Autobot::Media::Types.extension_for("Audio/OGG; codecs=opus", ".bin").should eq(".ogg")
    end

    it "knows mime aliases and falls back otherwise" do
      Autobot::Media::Types.extension_for("audio/x-m4a", ".bin").should eq(".m4a")
      Autobot::Media::Types.extension_for("application/x-unknown", ".bin").should eq(".bin")
      Autobot::Media::Types.extension_for(nil, ".bin").should eq(".bin")
    end
  end
end
