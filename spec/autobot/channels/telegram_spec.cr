require "../../spec_helper"

# Expose private methods for testing via a thin subclass.
class TelegramChannelTest < Autobot::Channels::TelegramChannel
  def test_access_denied_message(sender_id : String) : String
    access_denied_message(sender_id)
  end

  def test_command_description(entry : Autobot::Config::CustomCommandEntry, name : String) : String
    command_description(entry, name)
  end

  def test_format_cron_job_html(job : Autobot::Cron::CronJob, index : Int32, cron : Autobot::Cron::Service) : String
    format_cron_job_html(job, index, cron)
  end

  def test_format_cron_schedule_html(schedule : Autobot::Cron::CronSchedule) : String
    format_cron_schedule_html(schedule)
  end

  def test_format_cron_last_run(job : Autobot::Cron::CronJob) : String
    format_cron_last_run(job)
  end
end

private def build_channel(
  allow_from : Array(String) = [] of String,
  custom_commands : Autobot::Config::CustomCommandsConfig? = nil,
  cron_service : Autobot::Cron::Service? = nil,
) : TelegramChannelTest
  bus = Autobot::Bus::MessageBus.new
  cmds = custom_commands || Autobot::Config::CustomCommandsConfig.new
  TelegramChannelTest.new(
    bus: bus,
    token: "test-token",
    allow_from: allow_from,
    custom_commands: cmds,
    cron_service: cron_service,
  )
end

describe Autobot::Channels::TelegramChannel do
  describe "#access_denied_message" do
    it "shows setup instructions when allow_from is empty" do
      channel = build_channel(allow_from: [] of String)
      msg = channel.test_access_denied_message("12345|johndoe")

      msg.should contain("no authorized users yet")
      msg.should contain("allow_from")
      msg.should contain("config.yml")
      msg.should contain("12345|johndoe")
    end

    it "escapes HTML in sender ID" do
      channel = build_channel(allow_from: [] of String)
      msg = channel.test_access_denied_message("<script>alert(1)</script>")

      msg.should_not contain("<script>")
      msg.should contain("&lt;script&gt;")
    end

    it "shows generic denial when allow_from has users" do
      channel = build_channel(allow_from: ["allowed_user"])
      msg = channel.test_access_denied_message("other_user")

      msg.should contain("Access denied")
      msg.should contain("not in the authorized users list")
      msg.should_not contain("config.yml")
    end
  end

  describe "#command_description" do
    it "returns description when provided" do
      entry = Autobot::Config::CustomCommandEntry.new("prompt text", "My description")
      channel = build_channel
      channel.test_command_description(entry, "cmd").should eq("My description")
    end

    it "humanizes command name when no description" do
      entry = Autobot::Config::CustomCommandEntry.new("prompt text")
      channel = build_channel
      channel.test_command_description(entry, "check_status").should eq("Check status")
    end

    it "humanizes command name with hyphens" do
      entry = Autobot::Config::CustomCommandEntry.new("prompt text")
      channel = build_channel
      channel.test_command_description(entry, "run-deploy").should eq("Run deploy")
    end
  end

  describe "#format_cron_schedule_html" do
    it "formats every-interval schedule" do
      channel = build_channel
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 600_000_i64)
      channel.test_format_cron_schedule_html(schedule).should eq("⏱ Every 10 min")
    end

    it "formats every schedule with nil ms" do
      channel = build_channel
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every)
      channel.test_format_cron_schedule_html(schedule).should eq("⏱ Every ?")
    end

    it "formats cron expression with UTC label" do
      channel = build_channel
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "0 9 * * 1-5")
      channel.test_format_cron_schedule_html(schedule).should eq("🕐 0 9 * * 1-5 (UTC)")
    end

    it "formats at schedule with timestamp" do
      channel = build_channel
      at_ms = Time.utc(2026, 3, 1, 14, 0, 0).to_unix_ms
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::At, at_ms: at_ms)
      result = channel.test_format_cron_schedule_html(schedule)
      result.should contain("📌 One-time:")
      result.should contain("14:00 UTC")
    end

    it "formats at schedule without timestamp" do
      channel = build_channel
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::At)
      channel.test_format_cron_schedule_html(schedule).should eq("📌 One-time")
    end

    it "escapes HTML in cron expression" do
      channel = build_channel
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "<bad>")
      result = channel.test_format_cron_schedule_html(schedule)
      result.should contain("&lt;bad&gt;")
      result.should_not contain("<bad>")
    end
  end

  describe "#format_cron_last_run" do
    it "returns pending when no last run" do
      channel = build_channel
      job = Autobot::Cron::CronJob.new(id: "j1", name: "test")
      channel.test_format_cron_last_run(job).should eq("⏳ pending")
    end

    it "returns relative time when last run exists" do
      channel = build_channel
      state = Autobot::Cron::CronJobState.new(last_run_at_ms: Time.utc.to_unix_ms - 300_000)
      job = Autobot::Cron::CronJob.new(id: "j1", name: "test", state: state)
      result = channel.test_format_cron_last_run(job)
      result.should start_with("✅")
      result.should contain("5 min ago")
    end
  end

  describe "#format_cron_job_html" do
    it "formats a complete job entry" do
      tmp = TestHelper.tmp_dir
      cron = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      channel = build_channel(cron_service: cron)

      job = Autobot::Cron::CronJob.new(
        id: "abc123",
        name: "Stars check",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 600_000_i64),
        payload: Autobot::Cron::CronPayload.new(message: "Check GitHub stars"),
      )

      result = channel.test_format_cron_job_html(job, 1, cron)
      result.should contain("<b>1.</b>")
      result.should contain("abc123")
      result.should contain("Stars check")
      result.should contain("⏱ Every 10 min")
      result.should contain("⏳ pending")
      result.should contain("📝")
      result.should contain("Check GitHub stars")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "produces output that splits within Telegram limits" do
      tmp = TestHelper.tmp_dir
      cron = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      channel = build_channel(cron_service: cron)

      lines = ["<b>Scheduled jobs (20)</b>"]
      20.times do |i|
        job = Autobot::Cron::CronJob.new(
          id: "job#{i}",
          name: "A long job name for testing #{"x" * 20}",
          schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 600_000_i64),
          payload: Autobot::Cron::CronPayload.new(message: "Detailed instruction " * 10),
        )
        lines << channel.test_format_cron_job_html(job, i + 1, cron)
      end

      text = lines.join("\n\n")
      text.size.should be > Autobot::Channels::MarkdownToTelegramHTML::TELEGRAM_MAX_LENGTH

      chunks = Autobot::Channels::MarkdownToTelegramHTML.split_message(text)
      chunks.size.should be > 1
      chunks.each { |chunk| chunk.size.should be <= Autobot::Channels::MarkdownToTelegramHTML::TELEGRAM_MAX_LENGTH }
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "escapes HTML in job name and message" do
      tmp = TestHelper.tmp_dir
      cron = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      channel = build_channel(cron_service: cron)

      job = Autobot::Cron::CronJob.new(
        id: "x1",
        name: "<script>alert</script>",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60_000_i64),
        payload: Autobot::Cron::CronPayload.new(message: "Use <tool> to check"),
      )

      result = channel.test_format_cron_job_html(job, 1, cron)
      result.should_not contain("<script>")
      result.should contain("&lt;script&gt;")
      result.should contain("&lt;tool&gt;")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end
end
