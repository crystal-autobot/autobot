require "../spec_helper"

describe Autobot do
  describe "VERSION" do
    it "is a valid semver string" do
      Autobot::VERSION.should match(/^\d+\.\d+\.\d+/)
    end

    it "matches shard.yml version" do
      shard_content = File.read(Path[__DIR__].parent.parent / "shard.yml")
      shard_version = shard_content.match!(/^version:\s*(\S+)/m)[1].strip
      Autobot::VERSION.should eq(shard_version)
    end
  end
end
