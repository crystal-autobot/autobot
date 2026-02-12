require "../../spec_helper"

describe Autobot::Cron::CronSchedule do
  it "creates an every-interval schedule" do
    schedule = Autobot::Cron::CronSchedule.new(
      kind: Autobot::Cron::ScheduleKind::Every,
      every_ms: 3600000_i64
    )
    schedule.kind.should eq(Autobot::Cron::ScheduleKind::Every)
    schedule.every_ms.should eq(3600000_i64)
  end

  it "creates a one-time schedule" do
    schedule = Autobot::Cron::CronSchedule.new(
      kind: Autobot::Cron::ScheduleKind::At,
      at_ms: 1700000000000_i64
    )
    schedule.kind.should eq(Autobot::Cron::ScheduleKind::At)
    schedule.at_ms.should eq(1700000000000_i64)
  end

  it "creates a cron expression schedule" do
    schedule = Autobot::Cron::CronSchedule.new(
      kind: Autobot::Cron::ScheduleKind::Cron,
      expr: "0 9 * * *"
    )
    schedule.kind.should eq(Autobot::Cron::ScheduleKind::Cron)
    schedule.expr.should eq("0 9 * * *")
  end

  it "serializes to JSON" do
    schedule = Autobot::Cron::CronSchedule.new(
      kind: Autobot::Cron::ScheduleKind::Every,
      every_ms: 60000_i64
    )
    json = schedule.to_json
    parsed = Autobot::Cron::CronSchedule.from_json(json)
    parsed.kind.should eq(Autobot::Cron::ScheduleKind::Every)
    parsed.every_ms.should eq(60000_i64)
  end
end

describe Autobot::Cron::CronPayload do
  it "creates a default payload" do
    payload = Autobot::Cron::CronPayload.new
    payload.kind.should eq(Autobot::Cron::PayloadKind::AgentTurn)
    payload.message.should eq("")
    payload.deliver?.should be_false
  end

  it "creates a delivery payload" do
    payload = Autobot::Cron::CronPayload.new(
      message: "Good morning!",
      deliver: true,
      channel: "telegram",
      to: "user123"
    )
    payload.message.should eq("Good morning!")
    payload.deliver?.should be_true
    payload.channel.should eq("telegram")
    payload.to.should eq("user123")
  end
end

describe Autobot::Cron::CronJob do
  it "creates a job with defaults" do
    job = Autobot::Cron::CronJob.new(id: "abc123", name: "test_job")
    job.id.should eq("abc123")
    job.name.should eq("test_job")
    job.enabled?.should be_true
    job.delete_after_run?.should be_false
  end

  it "serializes to JSON and back" do
    job = Autobot::Cron::CronJob.new(
      id: "test1",
      name: "morning greeting",
      schedule: Autobot::Cron::CronSchedule.new(
        kind: Autobot::Cron::ScheduleKind::Cron,
        expr: "0 9 * * *"
      ),
      payload: Autobot::Cron::CronPayload.new(
        message: "Good morning!",
        deliver: true,
        channel: "telegram"
      ),
      created_at_ms: 1700000000000_i64
    )

    json = job.to_json
    restored = Autobot::Cron::CronJob.from_json(json)
    restored.id.should eq("test1")
    restored.name.should eq("morning greeting")
    restored.schedule.expr.should eq("0 9 * * *")
    restored.payload.message.should eq("Good morning!")
  end
end

describe Autobot::Cron::CronStore do
  it "creates an empty store" do
    store = Autobot::Cron::CronStore.new
    store.version.should eq(1)
    store.jobs.should be_empty
  end

  it "serializes with jobs" do
    store = Autobot::Cron::CronStore.new
    store.jobs << Autobot::Cron::CronJob.new(id: "j1", name: "job1")
    store.jobs << Autobot::Cron::CronJob.new(id: "j2", name: "job2")

    json = store.to_json
    restored = Autobot::Cron::CronStore.from_json(json)
    restored.jobs.size.should eq(2)
    restored.jobs[0].name.should eq("job1")
  end
end
