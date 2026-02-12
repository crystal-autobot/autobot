require "../../spec_helper"

describe Autobot::Config::Loader do
  describe ".load" do
    it "raises when explicit config file is not found" do
      expect_raises(Exception, /Config file not found/) do
        Autobot::Config::Loader.load("/nonexistent/path.yml")
      end
    end

    it "returns default config when no config files exist" do
      config = Autobot::Config::Loader.load(nil)
      config.should be_a(Autobot::Config::Config)
    end

    it "loads config from explicit path" do
      tmp = TestHelper.tmp_dir
      config_path = tmp / "config.yml"
      File.write(config_path, <<-YAML
      providers:
        anthropic:
          api_key: "test-key"
      YAML
      )

      config = Autobot::Config::Loader.load(config_path.to_s)
      config.providers.try(&.anthropic.try(&.api_key)).should eq("test-key")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "raises for another nonexistent explicit config path" do
      expect_raises(Exception, /Config file not found/) do
        Autobot::Config::Loader.load("/definitely/does/not/exist.yml")
      end
    end
  end

  describe ".data_dir" do
    it "returns path under home directory" do
      dir = Autobot::Config::Loader.data_dir
      dir.to_s.should contain("autobot")
    end
  end

  describe ".sessions_dir" do
    it "returns sessions subdirectory" do
      dir = Autobot::Config::Loader.sessions_dir
      dir.to_s.should end_with("sessions")
    end
  end

  describe ".skills_dir" do
    it "returns skills subdirectory" do
      dir = Autobot::Config::Loader.skills_dir
      dir.to_s.should end_with("skills")
    end
  end

  describe ".save" do
    it "saves config to a file" do
      tmp = TestHelper.tmp_dir
      config_path = tmp / "saved_config.yml"

      config = Autobot::Config::Config.new
      Autobot::Config::Loader.save(config, config_path.to_s)

      File.exists?(config_path).should be_true
      content = File.read(config_path)
      content.should contain("---")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe ".init_dirs" do
    it "creates required directories" do
      Autobot::Config::Loader.init_dirs
      Dir.exists?(Autobot::Config::Loader.data_dir).should be_true
    end
  end
end
