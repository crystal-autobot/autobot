require "../../spec_helper"

describe Autobot::CLI::Gateway do
  describe ".log_sandbox_info" do
    it "logs disabled warning when sandbox_config is none even if bubblewrap is detected" do
      io = IO::Memory.new
      err_io = IO::Memory.new
      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::Bubblewrap
      Autobot::Tools::Sandbox.configure("none")

      Autobot::CLI::Gateway.log_sandbox_info(io, err_io)

      io.to_s.should contain("Sandbox: disabled (direct execution, dev only)")
      err_io.to_s.should be_empty
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
      err_io.to_s.should contain("Sandbox: unavailable (install bubblewrap or docker)")
    ensure
      Autobot::Tools::Sandbox.detect_override = nil
    end

    it "logs unavailable error when auto resolves to none" do
      io = IO::Memory.new
      err_io = IO::Memory.new
      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::None
      Autobot::Tools::Sandbox.configure("auto")

      Autobot::CLI::Gateway.log_sandbox_info(io, err_io)

      io.to_s.should be_empty
      err_io.to_s.should contain("Sandbox: unavailable (install bubblewrap or docker)")
    ensure
      Autobot::Tools::Sandbox.detect_override = nil
    end
  end
end
