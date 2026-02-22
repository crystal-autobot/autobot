require "../../spec_helper"

describe Autobot::Cron::Service do
  it "initializes with empty store" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
    jobs = service.list_jobs
    jobs.should be_empty
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "adds a recurring job" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

    job = service.add_job(
      name: "test_every",
      schedule: Autobot::Cron::CronSchedule.new(
        kind: Autobot::Cron::ScheduleKind::Every,
        every_ms: 60000_i64
      ),
      message: "Every minute!"
    )

    job.name.should eq("test_every")
    job.id.size.should eq(8)
    job.enabled?.should be_true
    job.payload.message.should eq("Every minute!")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "persists jobs to disk" do
    tmp = TestHelper.tmp_dir
    store_path = tmp / "cron.json"

    service = Autobot::Cron::Service.new(store_path: store_path)
    service.add_job(
      name: "persistent",
      schedule: Autobot::Cron::CronSchedule.new(
        kind: Autobot::Cron::ScheduleKind::Every,
        every_ms: 3600000_i64
      ),
      message: "Hello"
    )

    File.exists?(store_path).should be_true
    content = File.read(store_path)
    content.should contain("persistent")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "removes a job by ID" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

    job = service.add_job(
      name: "removable",
      schedule: Autobot::Cron::CronSchedule.new(
        kind: Autobot::Cron::ScheduleKind::Every,
        every_ms: 60000_i64
      ),
      message: "bye"
    )

    service.remove_job(job.id).should be_true
    service.list_jobs.should be_empty
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns false when removing nonexistent job" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
    service.remove_job("nonexistent").should be_false
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "enables and disables a job" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

    job = service.add_job(
      name: "toggle",
      schedule: Autobot::Cron::CronSchedule.new(
        kind: Autobot::Cron::ScheduleKind::Every,
        every_ms: 60000_i64
      ),
      message: "toggle me"
    )

    # Disable
    updated = service.enable_job(job.id, enabled: false)
    updated.should_not be_nil
    updated.try(&.enabled?).should be_false

    # Re-enable
    updated = service.enable_job(job.id, enabled: true)
    updated.should_not be_nil
    updated.try(&.enabled?).should be_true
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "enforces owner on enable_job" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

    job = service.add_job(
      name: "owned_toggle",
      schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
      message: "toggle me",
      owner: "telegram:user1"
    )

    service.enable_job(job.id, enabled: false, owner: "telegram:user2").should be_nil
    service.list_jobs.first.enabled?.should be_true

    service.enable_job(job.id, enabled: false, owner: "telegram:user1").should_not be_nil
    service.list_jobs(include_disabled: true).find { |j| j.id == job.id }.try(&.enabled?).should be_false
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "lists only enabled jobs by default" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

    service.add_job(
      name: "active",
      schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
      message: "active"
    )
    j2 = service.add_job(
      name: "inactive",
      schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
      message: "inactive"
    )
    service.enable_job(j2.id, enabled: false)

    service.list_jobs.size.should eq(1)
    service.list_jobs(include_disabled: true).size.should eq(2)
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "returns status info" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
    status = service.status
    status["enabled"].as_bool.should be_false # Not started yet
    status["jobs"].as_i.should eq(0)
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  describe "owner-scoped operations" do
    it "filters jobs by owner" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      service.add_job(
        name: "user1_job",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "user1",
        owner: "telegram:user1"
      )
      service.add_job(
        name: "user2_job",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "user2",
        owner: "telegram:user2"
      )

      user1_jobs = service.list_jobs(owner: "telegram:user1")
      user1_jobs.size.should eq(1)
      user1_jobs.first.name.should eq("user1_job")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "prevents removing job with wrong owner" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "owned",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "test",
        owner: "telegram:user1"
      )

      service.remove_job(job.id, owner: "telegram:user2").should be_false
      service.list_jobs.size.should eq(1)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "gets a job by ID" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "findable",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "find me",
        owner: "telegram:user1"
      )

      found = service.get_job(job.id)
      found.should_not be_nil
      found.try(&.name).should eq("findable")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "gets a job by ID with matching owner" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "owned",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "mine",
        owner: "telegram:user1"
      )

      found = service.get_job(job.id, owner: "telegram:user1")
      found.should_not be_nil
      found.try(&.name).should eq("owned")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns nil for wrong owner" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "secret",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "hidden",
        owner: "telegram:user1"
      )

      service.get_job(job.id, owner: "telegram:user2").should be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns nil for nonexistent job ID" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      service.get_job("nonexistent").should be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "allows removing job with correct owner" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "owned",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "test",
        owner: "telegram:user1"
      )

      service.remove_job(job.id, owner: "telegram:user1").should be_true
      service.list_jobs.should be_empty
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "#update_job" do
    it "updates schedule" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "updatable",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "original"
      )

      new_schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "0 9 * * *")
      updated = service.update_job(job.id, schedule: new_schedule)

      updated.should_not be_nil
      updated.try(&.schedule.kind).should eq(Autobot::Cron::ScheduleKind::Cron)
      updated.try(&.schedule.expr).should eq("0 9 * * *")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "updates message" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "updatable",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "original",
        deliver: true,
        channel: "telegram",
        to: "user1"
      )

      updated = service.update_job(job.id, message: "new message")

      updated.should_not be_nil
      updated.try(&.payload.message).should eq("new message")
      updated.try(&.payload.deliver?).should be_true
      updated.try(&.payload.channel).should eq("telegram")
      updated.try(&.payload.to).should eq("user1")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "updates both schedule and message" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "updatable",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "original"
      )

      new_schedule = Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "0 8 * * *")
      updated = service.update_job(job.id, schedule: new_schedule, message: "updated")

      updated.should_not be_nil
      updated.try(&.schedule.expr).should eq("0 8 * * *")
      updated.try(&.payload.message).should eq("updated")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "preserves created_at_ms, state, and owner" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "updatable",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "original",
        owner: "telegram:user1"
      )
      original_created = job.created_at_ms

      updated = service.update_job(job.id, owner: "telegram:user1", message: "changed")

      updated.should_not be_nil
      updated.try(&.created_at_ms).should eq(original_created)
      updated.try(&.owner).should eq("telegram:user1")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "updates updated_at_ms" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "updatable",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "original"
      )
      original_updated = job.updated_at_ms

      sleep 1.milliseconds
      updated = service.update_job(job.id, message: "changed")

      updated.should_not be_nil
      (updated.as(Autobot::Cron::CronJob).updated_at_ms >= original_updated).should be_true
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "rejects update with wrong owner" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "owned",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "original",
        owner: "telegram:user1"
      )

      result = service.update_job(job.id, owner: "telegram:user2", message: "hacked")
      result.should be_nil

      # Original message unchanged
      jobs = service.list_jobs
      jobs.first.payload.message.should eq("original")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns nil for non-existent job" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      result = service.update_job("nonexistent", message: "test")
      result.should be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "persists changes to disk" do
      tmp = TestHelper.tmp_dir
      store_path = tmp / "cron.json"
      service = Autobot::Cron::Service.new(store_path: store_path)

      job = service.add_job(
        name: "persist_test",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "original"
      )

      service.update_job(job.id, message: "persisted change")

      service2 = Autobot::Cron::Service.new(store_path: store_path)
      jobs = service2.list_jobs
      jobs.first.payload.message.should eq("persisted change")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "#clear_all" do
    it "removes all jobs and returns count" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      service.add_job(
        name: "job1",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "first"
      )
      service.add_job(
        name: "job2",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "second"
      )

      service.clear_all.should eq(2)
      service.list_jobs.should be_empty
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns zero when no jobs exist" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      service.clear_all.should eq(0)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "persists empty store to disk" do
      tmp = TestHelper.tmp_dir
      store_path = tmp / "cron.json"
      service = Autobot::Cron::Service.new(store_path: store_path)

      service.add_job(
        name: "to_clear",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "test"
      )
      service.clear_all

      service2 = Autobot::Cron::Service.new(store_path: store_path)
      service2.list_jobs.should be_empty
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "delete_after_run" do
    it "marks one-time jobs with delete_after_run" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "one_shot",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::At, at_ms: Time.utc.to_unix_ms + 60000),
        message: "once",
        delete_after_run: true
      )

      job.delete_after_run?.should be_true
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "cron expression scheduling" do
    it "schedules * * * * * to the next minute" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      now = Time.utc
      job = service.add_job(
        name: "every_min",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "* * * * *"),
        message: "ping"
      )

      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil

      # Should be within 2 minutes from now (next minute boundary)
      diff_ms = next_run.as(Int64) - now.to_unix_ms
      diff_ms.should be > 0
      diff_ms.should be <= 120_000
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "schedules fixed minute with wildcard hour" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      now = Time.utc
      job = service.add_job(
        name: "on_the_half",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "30 * * * *"),
        message: "half past"
      )

      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil

      next_time = Time.unix_ms(next_run.as(Int64))
      next_time.minute.should eq(30)
      next_time.should be > now
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "schedules fixed hour and minute" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      now = Time.utc
      job = service.add_job(
        name: "daily_9am",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "0 9 * * *"),
        message: "morning"
      )

      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil

      next_time = Time.unix_ms(next_run.as(Int64))
      next_time.hour.should eq(9)
      next_time.minute.should eq(0)
      next_time.should be > now
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "schedules wildcard minute with fixed hour" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "noon_start",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "* 12 * * *"),
        message: "noon"
      )

      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil

      next_time = Time.unix_ms(next_run.as(Int64))
      next_time.hour.should eq(12)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "computes next run relative to last_run, not now" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "relative",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "* * * * *"),
        message: "tick"
      )

      # Simulate last run 5 minutes ago
      five_min_ago = Time.utc.to_unix_ms - 300_000
      job.state = job.state.copy(last_run_at_ms: five_min_ago)

      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil

      # Next run should be ~4 minutes ago (next minute after last_run),
      # not in the future
      next_run_ms = next_run.as(Int64)
      next_run_ms.should be < Time.utc.to_unix_ms
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "cron job becomes due when next occurrence is in the past" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "due_check",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "* * * * *"),
        message: "check"
      )

      # Simulate last run 2 minutes ago
      two_min_ago = Time.utc.to_unix_ms - 120_000
      job.state = job.state.copy(last_run_at_ms: two_min_ago)

      now = Time.utc.to_unix_ms
      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil

      # Job should be due: now >= next_run
      (now >= next_run.as(Int64)).should be_true
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "cron job is not due immediately after running" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "just_ran",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "* * * * *"),
        message: "check"
      )

      # Simulate last run just now
      job.state = job.state.copy(last_run_at_ms: Time.utc.to_unix_ms)

      now = Time.utc.to_unix_ms
      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil

      # Job should NOT be due yet (next run is ~1 minute from now)
      (now >= next_run.as(Int64)).should be_false
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "supports step expressions like */5" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "every_5min",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "*/5 * * * *"),
        message: "five"
      )

      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil

      next_time = Time.unix_ms(next_run.as(Int64))
      (next_time.minute % 5).should eq(0)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "supports range expressions like 9-17" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "work_hours",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "0 9-17 * * *"),
        message: "work"
      )

      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil

      next_time = Time.unix_ms(next_run.as(Int64))
      next_time.hour.should be >= 9
      next_time.hour.should be <= 17
      next_time.minute.should eq(0)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns nil for invalid expression" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "bad_expr",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Cron, expr: "invalid"),
        message: "nope"
      )

      service.compute_next_run_for(job).should be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "service lifecycle" do
    it "starts with zero jobs and accepts jobs later" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      # Start with no jobs
      service.start
      service.status["enabled"].as_bool.should be_true
      service.list_jobs.should be_empty

      # Add a job after start — should work
      job = service.add_job(
        name: "dynamic",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "added after start"
      )

      service.list_jobs.size.should eq(1)

      # Next run should be in the future (not stuck in the past)
      next_run = service.compute_next_run_for(job)
      next_run.should_not be_nil
      (next_run.as(Int64) > Time.utc.to_unix_ms).should be_true

      service.stop
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "is not running before start is called" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      service.status["enabled"].as_bool.should be_false
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "reports running after start" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      service.start
      service.status["enabled"].as_bool.should be_true
      service.stop
      service.status["enabled"].as_bool.should be_false
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "reloads store on restart" do
      tmp = TestHelper.tmp_dir
      store_path = tmp / "cron.json"
      service = Autobot::Cron::Service.new(store_path: store_path)
      service.start

      service.add_job(
        name: "before_restart",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "persisted"
      )
      service.stop

      # Restart — should reload from disk
      service.start
      service.list_jobs.size.should eq(1)
      service.list_jobs.first.name.should eq("before_restart")
      service.stop
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "external store reload" do
    it "picks up jobs added externally to the store file" do
      tmp = TestHelper.tmp_dir
      store_path = tmp / "cron.json"

      # Server service loads empty store
      server = Autobot::Cron::Service.new(store_path: store_path)
      server.list_jobs.should be_empty

      # CLI service writes a job to disk
      cli = Autobot::Cron::Service.new(store_path: store_path)
      cli.add_job(
        name: "cli_job",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "from cli"
      )

      # Server still has empty in-memory store
      server.list_jobs.should be_empty

      # After start (which reloads), server sees the job
      server.start
      server.list_jobs.size.should eq(1)
      server.list_jobs.first.name.should eq("cli_job")
      server.stop
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  it "loads existing store from disk" do
    tmp = TestHelper.tmp_dir
    store_path = tmp / "cron.json"

    # Create store with a job
    service1 = Autobot::Cron::Service.new(store_path: store_path)
    service1.add_job(
      name: "saved",
      schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
      message: "saved job"
    )

    # Create new service, should load from disk
    service2 = Autobot::Cron::Service.new(store_path: store_path)
    jobs = service2.list_jobs
    jobs.size.should eq(1)
    jobs[0].name.should eq("saved")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
