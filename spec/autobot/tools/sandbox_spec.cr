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

  describe ".docker_image" do
    it "defaults to nil" do
      Autobot::Tools::Sandbox.docker_image.should be_nil
    end

    it "can be set to a custom image" do
      Autobot::Tools::Sandbox.docker_image = "python:3.14-alpine"
      Autobot::Tools::Sandbox.docker_image.should eq("python:3.14-alpine")
    ensure
      Autobot::Tools::Sandbox.docker_image = nil
    end
  end

  describe ".resolve_sandbox_image" do
    it "does nothing when explicit docker_image is set" do
      tmp = TestHelper.tmp_dir
      File.write(tmp / "Dockerfile.sandbox", "FROM alpine:latest")

      Autobot::Tools::Sandbox.docker_image = "custom:image"
      Autobot::Tools::Sandbox.resolve_sandbox_image(tmp)
      Autobot::Tools::Sandbox.docker_image.should eq("custom:image")
    ensure
      Autobot::Tools::Sandbox.docker_image = nil
      FileUtils.rm_rf(tmp) if tmp
    end

    it "does nothing when no Dockerfile.sandbox exists" do
      tmp = TestHelper.tmp_dir
      Autobot::Tools::Sandbox.resolve_sandbox_image(tmp)
      Autobot::Tools::Sandbox.docker_image.should be_nil
    ensure
      Autobot::Tools::Sandbox.docker_image = nil
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "constants" do
    it "has sandbox dockerfile name" do
      Autobot::Tools::Sandbox::SANDBOX_DOCKERFILE.should eq("Dockerfile.sandbox")
    end

    it "has sandbox image tag" do
      Autobot::Tools::Sandbox::SANDBOX_IMAGE_TAG.should eq("autobot-sandbox")
    end
  end
end
