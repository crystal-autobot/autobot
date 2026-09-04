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
