require "../../spec_helper"

describe Autobot::Cron do
  describe ".owner_key" do
    it "builds channel:chat_id format" do
      Autobot::Cron.owner_key("telegram", "12345").should eq("telegram:12345")
    end
  end
end

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

describe Autobot::Cron::CronJobState do
  it "creates with nil fields by default" do
    state = Autobot::Cron::CronJobState.new
    state.last_run_at_ms.should be_nil
    state.last_status.should be_nil
  end

  it "serializes to JSON and back" do
    state = Autobot::Cron::CronJobState.new(
      last_run_at_ms: 1700000000000_i64,
      last_status: Autobot::Cron::JobStatus::Ok,
    )

    json = state.to_json
    restored = Autobot::Cron::CronJobState.from_json(json)
    restored.last_run_at_ms.should eq(1700000000000_i64)
    restored.last_status.should eq(Autobot::Cron::JobStatus::Ok)
  end
end

describe Autobot::Cron::CronJob do
  it "creates a job with defaults" do
    job = Autobot::Cron::CronJob.new(id: "abc123", name: "test_job")
    job.id.should eq("abc123")
    job.name.should eq("test_job")
    job.enabled?.should be_true
    job.delete_after_run?.should be_false
    job.owner.should be_nil
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

  it "serializes job with owner" do
    job = Autobot::Cron::CronJob.new(
      id: "s1",
      name: "owned",
      owner: "telegram:user123"
    )

    json = job.to_json
    restored = Autobot::Cron::CronJob.from_json(json)
    restored.owner.should eq("telegram:user123")
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

describe Autobot::Cron::ScheduleBuilder do
  it "builds an every-interval schedule" do
    result = Autobot::Cron::ScheduleBuilder.build(every_seconds: 300_i64, cron_expr: nil, at: nil)
    if r = result
      schedule, delete_after = r
      schedule.kind.should eq(Autobot::Cron::ScheduleKind::Every)
      schedule.every_ms.should eq(300000_i64)
      delete_after.should be_false
    else
      fail "expected a schedule result"
    end
  end

  it "builds a cron expression schedule" do
    result = Autobot::Cron::ScheduleBuilder.build(every_seconds: nil, cron_expr: "0 9 * * *", at: nil)
    if r = result
      schedule, delete_after = r
      schedule.kind.should eq(Autobot::Cron::ScheduleKind::Cron)
      schedule.expr.should eq("0 9 * * *")
      delete_after.should be_false
    else
      fail "expected a schedule result"
    end
  end

  it "builds a one-time schedule with delete_after_run" do
    result = Autobot::Cron::ScheduleBuilder.build(every_seconds: nil, cron_expr: nil, at: "2026-03-01T10:00:00Z")
    if r = result
      schedule, delete_after = r
      schedule.kind.should eq(Autobot::Cron::ScheduleKind::At)
      schedule.at_ms.should_not be_nil
      delete_after.should be_true
    else
      fail "expected a schedule result"
    end
  end

  it "returns nil when no params given" do
    result = Autobot::Cron::ScheduleBuilder.build(every_seconds: nil, cron_expr: nil, at: nil)
    result.should be_nil
  end

  it "raises on zero every_seconds" do
    expect_raises(ArgumentError, /at least 1/) do
      Autobot::Cron::ScheduleBuilder.build(every_seconds: 0_i64, cron_expr: nil, at: nil)
    end
  end

  it "raises on negative every_seconds" do
    expect_raises(ArgumentError, /at least 1/) do
      Autobot::Cron::ScheduleBuilder.build(every_seconds: -10_i64, cron_expr: nil, at: nil)
    end
  end

  it "raises on past at timestamp" do
    past = (Time.utc - 1.hour).to_rfc3339
    expect_raises(ArgumentError, /at must be in the future/) do
      Autobot::Cron::ScheduleBuilder.build(every_seconds: nil, cron_expr: nil, at: past)
    end
  end

  it "prefers every_seconds over other params" do
    result = Autobot::Cron::ScheduleBuilder.build(every_seconds: 60_i64, cron_expr: "0 9 * * *", at: nil)
    if r = result
      schedule, _ = r
      schedule.kind.should eq(Autobot::Cron::ScheduleKind::Every)
    else
      fail "expected a schedule result"
    end
  end
end
