require "../../spec_helper"

describe Autobot::Cron::Formatter do
  describe ".format_schedule" do
    it "formats every schedule" do
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 600_000_i64)
      Autobot::Cron::Formatter.format_schedule(schedule).should eq("every 10 min")
    end

    it "formats every schedule in seconds" do
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 30_000_i64)
      Autobot::Cron::Formatter.format_schedule(schedule).should eq("every 30s")
    end

    it "formats every schedule in hours" do
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 7_200_000_i64)
      Autobot::Cron::Formatter.format_schedule(schedule).should eq("every 2h")
    end

    it "formats cron schedule" do
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "0 9 * * 1-5")
      Autobot::Cron::Formatter.format_schedule(schedule).should eq("0 9 * * 1-5")
    end

    it "formats at schedule with timestamp" do
      at_ms = Time.utc(2026, 3, 1, 14, 0, 0).to_unix_ms
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::At, at_ms: at_ms)
      Autobot::Cron::Formatter.format_schedule(schedule).should eq("one-time: 2026-03-01 14:00 UTC")
    end

    it "formats every with nil ms" do
      schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every)
      Autobot::Cron::Formatter.format_schedule(schedule).should eq("every ?")
    end
  end

  describe ".format_relative_time" do
    it "returns pending for nil" do
      Autobot::Cron::Formatter.format_relative_time(nil).should eq("pending")
    end

    it "returns just now for recent past" do
      now_ms = Time.utc.to_unix_ms
      Autobot::Cron::Formatter.format_relative_time(now_ms - 10_000).should eq("just now")
    end

    it "returns minutes ago for past minutes" do
      now_ms = Time.utc.to_unix_ms
      Autobot::Cron::Formatter.format_relative_time(now_ms - 300_000).should eq("5 min ago")
    end

    it "returns hours ago for past hours" do
      now_ms = Time.utc.to_unix_ms
      Autobot::Cron::Formatter.format_relative_time(now_ms - 7_200_000).should eq("2h ago")
    end

    it "returns future time" do
      now_ms = Time.utc.to_unix_ms
      Autobot::Cron::Formatter.format_relative_time(now_ms + 300_000).should eq("in 5 min")
    end

    it "returns in <1 min for near future" do
      now_ms = Time.utc.to_unix_ms
      Autobot::Cron::Formatter.format_relative_time(now_ms + 10_000).should eq("in <1 min")
    end
  end

  describe ".format_duration" do
    it "formats seconds" do
      Autobot::Cron::Formatter.format_duration(30_000_i64).should eq("30s")
    end

    it "formats minutes" do
      Autobot::Cron::Formatter.format_duration(600_000_i64).should eq("10 min")
    end

    it "formats hours" do
      Autobot::Cron::Formatter.format_duration(3_600_000_i64).should eq("1h")
    end

    it "formats days" do
      Autobot::Cron::Formatter.format_duration(86_400_000_i64).should eq("1d")
    end
  end
end
