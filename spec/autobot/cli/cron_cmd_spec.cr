require "../../spec_helper"

describe Autobot::CLI::CronCmd do
  describe ".cron_service" do
    it "resolves default and custom cron.store_path relative to the given config_path directory" do
      original_config_dir = Autobot::Config::Loader.config_dir
      tmp = TestHelper.tmp_dir
      other_dir = TestHelper.tmp_dir
      config_file = tmp / "config.yml"
      File.write(config_file, "cron:\n  store_path: custom/jobs.json\n")

      seeded = Autobot::Cron::Service.new(tmp / "custom" / "jobs.json")
      job = seeded.add_job(
        name: "seeded_job",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "hello",
      )

      other_config = other_dir / "config.yml"
      File.write(other_config, "{}\n")
      Autobot::Config::Loader.load(other_config.to_s, validate: false)

      service = Autobot::CLI::CronCmd.cron_service(config_file.to_s)
      found = service.get_job(job.id)
      found.should_not be_nil
      found.try(&.name).should eq("seeded_job")
    ensure
      Autobot::Config::Loader.config_dir = original_config_dir if original_config_dir
      FileUtils.rm_rf(tmp) if tmp
      FileUtils.rm_rf(other_dir) if other_dir
    end

    it "falls back to cron.json for read-only commands and raises on invalid -c for mutating commands" do
      original_config_dir = Autobot::Config::Loader.config_dir
      tmp = TestHelper.tmp_dir

      seeded = Autobot::Cron::Service.new(tmp / "cron.json")
      job = seeded.add_job(
        name: "fallback_job",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "hello",
      )

      missing_path = (tmp / "missing.yml").to_s
      readonly_service = Autobot::CLI::CronCmd.cron_service(missing_path, fallback: true)
      readonly_service.get_job(job.id).try(&.name).should eq("fallback_job")

      expect_raises(Exception, /Config file not found/) do
        Autobot::CLI::CronCmd.cron_service(missing_path)
      end

      invalid_config = tmp / "config.yml"
      File.write(invalid_config, "invalid: [yaml\n")
      invalid_service = Autobot::CLI::CronCmd.cron_service(invalid_config.to_s, fallback: true)
      invalid_service.get_job(job.id).try(&.name).should eq("fallback_job")

      expect_raises(Exception, /Invalid YAML/) do
        Autobot::CLI::CronCmd.cron_service(invalid_config.to_s)
      end
    ensure
      Autobot::Config::Loader.config_dir = original_config_dir if original_config_dir
      FileUtils.rm_rf(tmp) if tmp
    end

    it "does not clobber resolved Tools::Sandbox.docker_image in Cron::Service.from_config" do
      Autobot::Tools::Sandbox.docker_image = "autobot-sandbox"
      config = Autobot::Config::Config.from_yaml("tools:\n  sandbox: docker\n")

      Autobot::Cron::Service.from_config(config)

      Autobot::Tools::Sandbox.docker_image.should eq("autobot-sandbox")
    ensure
      Autobot::Tools::Sandbox.docker_image = nil
    end
  end

  describe ".execute_run_job" do
    it "prints exec output and returns true when an exec job succeeds" do
      original_config_dir = Autobot::Config::Loader.config_dir
      tmp = TestHelper.tmp_dir
      config_file = tmp / "config.yml"
      File.write(config_file, "tools:\n  sandbox: none\n")

      seeded = Autobot::Cron::Service.new(tmp / "cron.json", sandbox_config: "none")
      job = seeded.add_job(
        name: "echo_exec",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        kind: Autobot::Cron::PayloadKind::Exec,
        command: "echo 'cron exec output'",
      )

      out_io = IO::Memory.new
      err_io = IO::Memory.new
      result = Autobot::CLI::CronCmd.execute_run_job(config_file.to_s, job.id, force: true, io: out_io, err_io: err_io)

      result.should be_true
      out_io.to_s.should contain("cron exec output")
      out_io.to_s.should contain("✓ Job executed")
      err_io.to_s.should be_empty
    ensure
      Autobot::Config::Loader.config_dir = original_config_dir if original_config_dir
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns false, prints error, and preserves one-shot --at job when execution fails" do
      original_config_dir = Autobot::Config::Loader.config_dir
      tmp = TestHelper.tmp_dir
      workspace = tmp / "workspace"
      Dir.mkdir_p(workspace)
      config_file = tmp / "config.yml"
      File.write(config_file, <<-YAML
      agents:
        defaults:
          workspace: "./workspace"
      tools:
        sandbox: "auto"
        docker_image: "custom:cron-sandbox"
        sandbox_env: ["CRON_TEST_VAR"]
      cron:
        exec_timeout: 5
      YAML
      )

      seeded = Autobot::Cron::Service.new(tmp / "cron.json")
      job = seeded.add_job(
        name: "sandboxed_one_shot",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::At, at_ms: Time.utc.to_unix_ms + 60000),
        kind: Autobot::Cron::PayloadKind::Exec,
        command: "echo should_require_sandbox",
        delete_after_run: true,
      )

      Autobot::Tools::Sandbox.detect_override = Autobot::Tools::Sandbox::Type::None

      out_io = IO::Memory.new
      err_io = IO::Memory.new
      result = Autobot::CLI::CronCmd.execute_run_job(config_file.to_s, job.id, force: true, io: out_io, err_io: err_io)

      result.should be_false
      out_io.to_s.should_not contain("✓ Job executed")
      err_io.to_s.should contain("No sandbox tool found")
      Autobot::Tools::Sandbox.docker_image.should eq("custom:cron-sandbox")
      Autobot::Tools::Sandbox.sandbox_env.should eq(["CRON_TEST_VAR"])

      reloaded = Autobot::Cron::Service.new(tmp / "cron.json")
      kept = reloaded.get_job(job.id)
      kept.should_not be_nil
      kept.try(&.enabled?).should be_false
      kept.try(&.state.last_status).should eq(Autobot::Cron::JobStatus::Error)
    ensure
      Autobot::Config::Loader.config_dir = original_config_dir if original_config_dir
      Autobot::Tools::Sandbox.detect_override = nil
      Autobot::Tools::Sandbox.docker_image = nil
      Autobot::Tools::Sandbox.sandbox_env = [] of String
      FileUtils.rm_rf(tmp) if tmp
    end

    it "executes agent turn jobs via on_job and records the output" do
      original_config_dir = Autobot::Config::Loader.config_dir
      tmp = TestHelper.tmp_dir
      workspace = tmp / "workspace"
      Dir.mkdir_p(workspace)

      server = HTTP::Server.new do |context|
        context.response.content_type = "application/json"
        context.response.print(text_response("Scheduled agent report complete."))
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }

      config_file = tmp / "config.yml"
      File.write(config_file, <<-YAML
      agents:
        defaults:
          model: "openai/gpt-4o"
          workspace: "./workspace"
      providers:
        openai:
          api_key: "test-key"
          api_base: "http://127.0.0.1:#{address.port}/v1"
      tools:
        sandbox: "none"
      plugins:
        sqlite:
          enabled: false
        github:
          enabled: false
        weather:
          enabled: false
      YAML
      )

      seeded = Autobot::Cron::Service.new(tmp / "cron.json", sandbox_config: "none")
      job = seeded.add_job(
        name: "agent_report",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "Generate the daily status report",
      )

      out_io = IO::Memory.new
      err_io = IO::Memory.new
      result = Autobot::CLI::CronCmd.execute_run_job(config_file.to_s, job.id, force: true, io: out_io, err_io: err_io)

      result.should be_true
      err_io.to_s.should be_empty
      out_io.to_s.should contain("Scheduled agent report complete.")
      out_io.to_s.should contain("✓ Job executed")

      reloaded = Autobot::Cron::Service.new(tmp / "cron.json", sandbox_config: "none")
      updated = reloaded.get_job(job.id)
      updated.should_not be_nil
      updated.try(&.state.last_status).should eq(Autobot::Cron::JobStatus::Ok)
      updated.try(&.state.last_output).should eq("Scheduled agent report complete.")
      File.exists?(workspace / "sessions" / "cli_direct.jsonl").should be_false
    ensure
      server.try(&.close)
      Autobot::Config::Loader.config_dir = original_config_dir if original_config_dir
      FileUtils.rm_rf(tmp) if tmp
    end
  end
end
