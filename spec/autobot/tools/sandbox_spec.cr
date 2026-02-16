require "../../spec_helper"

describe Autobot::Tools::Sandbox do
  describe ".resolve_type" do
    it "returns Bubblewrap for 'bubblewrap'" do
      Autobot::Tools::Sandbox.resolve_type("bubblewrap").should eq(Autobot::Tools::Sandbox::Type::Bubblewrap)
    end

    it "returns Docker for 'docker'" do
      Autobot::Tools::Sandbox.resolve_type("docker").should eq(Autobot::Tools::Sandbox::Type::Docker)
    end

    it "returns None for 'none'" do
      Autobot::Tools::Sandbox.resolve_type("none").should eq(Autobot::Tools::Sandbox::Type::None)
    end

    it "auto-detects for 'auto'" do
      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::Docker
      Autobot::Tools::Sandbox.resolve_type("auto").should eq(Autobot::Tools::Sandbox::Type::Docker)
    ensure
      Autobot::Tools::Sandbox.detect_override = nil
    end

    it "raises for invalid config" do
      expect_raises(ArgumentError, /Invalid sandbox config/) do
        Autobot::Tools::Sandbox.resolve_type("invalid")
      end
    end
  end
end
