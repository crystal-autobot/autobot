require "../../spec_helper"

describe Autobot::CLI::Gateway do
  describe ".log_sandbox_info" do
    it "warns about host exec when sandbox is none even if bubblewrap is detected" do
      io = IO::Memory.new
      err_io = IO::Memory.new
      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::Bubblewrap
      Autobot::Tools::Sandbox.configure("none")

      Autobot::CLI::Gateway.log_sandbox_info(io, err_io)

      io.to_s.should be_empty
      err_io.to_s.should contain("host exec enabled (sandbox: none): commands and skill scripts run on this host as")
    ensure
      Autobot::Tools::Sandbox.detect_override = nil
    end

    it "warns that an external sandbox is not verified" do
      io = IO::Memory.new
      err_io = IO::Memory.new
      Autobot::Tools::Sandbox.configure("external")

      Autobot::CLI::Gateway.log_sandbox_info(io, err_io)

      io.to_s.should be_empty
      err_io.to_s.should contain("Sandbox: external (not verified)")
    ensure
      Autobot::Tools::Sandbox.detect_override = nil
    end

    it "logs configured docker sandbox when docker is available" do
      io = IO::Memory.new
      err_io = IO::Memory.new
      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::Docker
      Autobot::Tools::Sandbox.configure("docker")

      Autobot::CLI::Gateway.log_sandbox_info(io, err_io)

      io.to_s.should contain("Sandbox: docker (container isolation)")
      err_io.to_s.should be_empty
    ensure
      Autobot::Tools::Sandbox.detect_override = nil
    end

    it "logs unavailable error when configured docker sandbox is not available on host" do
      io = IO::Memory.new
      err_io = IO::Memory.new
      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::Bubblewrap
      Autobot::Tools::Sandbox.configure("docker")

      Autobot::CLI::Gateway.log_sandbox_info(io, err_io)

      io.to_s.should be_empty
      err_io.to_s.should contain("Sandbox: unavailable (docker is configured but not installed)")
    ensure
      Autobot::Tools::Sandbox.detect_override = nil
    end

    it "refuses to configure auto when no backend is installed" do
      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::None

      expect_raises(Autobot::Tools::SandboxNotFoundError) do
        Autobot::Tools::Sandbox.configure("auto")
      end
    ensure
      Autobot::Tools::Sandbox.detect_override = nil
    end
  end
end
