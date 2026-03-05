require "../../spec_helper"

describe Autobot::CLI::Service do
  describe ".escape_xml" do
    it "escapes ampersands" do
      Autobot::CLI::Service.escape_xml("a&b").should eq("a&amp;b")
    end

    it "escapes angle brackets" do
      Autobot::CLI::Service.escape_xml("<script>").should eq("&lt;script&gt;")
    end

    it "returns plain strings unchanged" do
      Autobot::CLI::Service.escape_xml("hello").should eq("hello")
    end
  end

  describe ".load_env_vars" do
    it "returns empty hash for missing file" do
      Autobot::CLI::Service.load_env_vars("/nonexistent/.env").should be_empty
    end

    it "parses key=value pairs" do
      tmp = TestHelper.tmp_dir
      env_file = tmp / ".env"
      File.write(env_file, "API_KEY=abc123\nSECRET=xyz")

      begin
        vars = Autobot::CLI::Service.load_env_vars(env_file.to_s)
        vars["API_KEY"].should eq("abc123")
        vars["SECRET"].should eq("xyz")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "strips quotes from values" do
      tmp = TestHelper.tmp_dir
      env_file = tmp / ".env"
      File.write(env_file, "KEY=\"quoted_value\"")

      begin
        vars = Autobot::CLI::Service.load_env_vars(env_file.to_s)
        vars["KEY"].should eq("quoted_value")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    it "skips comments and empty lines" do
      tmp = TestHelper.tmp_dir
      env_file = tmp / ".env"
      File.write(env_file, "# comment\n\nKEY=value\n  # another comment")

      begin
        vars = Autobot::CLI::Service.load_env_vars(env_file.to_s)
        vars.size.should eq(1)
        vars["KEY"].should eq("value")
      ensure
        FileUtils.rm_rf(tmp)
      end
    end
  end

  describe ".render_systemd_unit" do
    it "generates a valid systemd unit file" do
      unit = Autobot::CLI::Service.render_systemd_unit(
        "/var/lib/autobot", "/usr/local/bin/autobot", "autobot"
      )

      unit.should contain("[Unit]")
      unit.should contain("[Service]")
      unit.should contain("[Install]")
      unit.should contain("User=autobot")
      unit.should contain("Group=autobot")
      unit.should contain("WorkingDirectory=/var/lib/autobot")
      unit.should contain("EnvironmentFile=/var/lib/autobot/.env")
      unit.should contain("ExecStart=/usr/local/bin/autobot gateway")
      unit.should contain("WantedBy=multi-user.target")
    end

    it "includes security hardening directives" do
      unit = Autobot::CLI::Service.render_systemd_unit(
        "/var/lib/autobot", "/usr/local/bin/autobot", "autobot"
      )

      unit.should contain("NoNewPrivileges=true")
      unit.should contain("ProtectSystem=strict")
      unit.should contain("ProtectHome=true")
      unit.should contain("ReadWritePaths=/var/lib/autobot")
    end

    it "omits ProtectHome when workspace is under home directory" do
      unit = Autobot::CLI::Service.render_systemd_unit(
        "/home/myuser/bot", "/opt/bin/autobot", "myuser"
      )

      unit.should_not contain("ProtectHome=true")
    end

    it "uses provided user and paths" do
      unit = Autobot::CLI::Service.render_systemd_unit(
        "/home/myuser/bot", "/opt/bin/autobot", "myuser"
      )

      unit.should contain("User=myuser")
      unit.should contain("Group=myuser")
      unit.should contain("WorkingDirectory=/home/myuser/bot")
      unit.should contain("ExecStart=/opt/bin/autobot gateway")
      unit.should contain("ReadWritePaths=/home/myuser/bot")
    end
  end

  describe ".render_launchd_plist" do
    it "generates a valid plist" do
      plist = Autobot::CLI::Service.render_launchd_plist(
        "/Users/me/bot", "/usr/local/bin/autobot", {} of String => String
      )

      plist.should contain("<?xml version=\"1.0\"")
      plist.should contain("<plist version=\"1.0\">")
      plist.should contain("<key>Label</key>")
      plist.should contain("<string>com.autobot.agent</string>")
      plist.should contain("<string>/usr/local/bin/autobot</string>")
      plist.should contain("<string>gateway</string>")
      plist.should contain("<string>/Users/me/bot</string>")
      plist.should contain("<key>RunAtLoad</key>")
      plist.should contain("<key>KeepAlive</key>")
    end

    it "includes environment variables when provided" do
      env = {"API_KEY" => "test123", "SECRET" => "xyz"}
      plist = Autobot::CLI::Service.render_launchd_plist(
        "/Users/me/bot", "/usr/local/bin/autobot", env
      )

      plist.should contain("<key>EnvironmentVariables</key>")
      plist.should contain("<key>API_KEY</key>")
      plist.should contain("<string>test123</string>")
      plist.should contain("<key>SECRET</key>")
      plist.should contain("<string>xyz</string>")
    end

    it "omits environment section when no vars" do
      plist = Autobot::CLI::Service.render_launchd_plist(
        "/Users/me/bot", "/usr/local/bin/autobot", {} of String => String
      )

      plist.should_not contain("<key>EnvironmentVariables</key>")
    end

    it "escapes XML special characters in env values" do
      env = {"KEY" => "a<b>&c"}
      plist = Autobot::CLI::Service.render_launchd_plist(
        "/Users/me/bot", "/usr/local/bin/autobot", env
      )

      plist.should contain("<string>a&lt;b&gt;&amp;c</string>")
    end

    it "configures log paths relative to working directory" do
      plist = Autobot::CLI::Service.render_launchd_plist(
        "/Users/me/bot", "/usr/local/bin/autobot", {} of String => String
      )

      plist.should contain("<key>StandardOutPath</key>")
      plist.should contain("<string>/Users/me/bot/logs/autobot.log</string>")
      plist.should contain("<key>StandardErrorPath</key>")
      plist.should contain("<string>/Users/me/bot/logs/autobot.error.log</string>")
    end
  end
end
