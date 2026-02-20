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

  describe "#set_state" do
    it "sets state on a job" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "stateful",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "check something"
      )

      state = JSON::Any.new({"count" => JSON::Any.new(42_i64)})
      service.set_state(job.id, state).should be_true
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "preserves other state fields" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "preserve",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "test"
      )

      original_next_run = job.state.next_run_at_ms

      state = JSON::Any.new({"key" => JSON::Any.new("value")})
      service.set_state(job.id, state)

      updated = service.list_jobs.first
      updated.state.next_run_at_ms.should eq(original_next_run)
      updated.state.state.should eq(state)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns false for nonexistent job" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      state = JSON::Any.new({"key" => JSON::Any.new("val")})
      service.set_state("nonexistent", state).should be_false
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "persists state to disk" do
      tmp = TestHelper.tmp_dir
      store_path = tmp / "cron.json"
      service = Autobot::Cron::Service.new(store_path: store_path)

      job = service.add_job(
        name: "persist_state",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "test"
      )

      state = JSON::Any.new({"steps" => JSON::Any.new(5000_i64)})
      service.set_state(job.id, state)

      # Reload from disk
      service2 = Autobot::Cron::Service.new(store_path: store_path)
      service2.get_state(job.id).should eq(state)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "#get_state" do
    it "returns nil when no state is set" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "no_state",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "test"
      )

      service.get_state(job.id).should be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns nil for nonexistent job" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      service.get_state("nonexistent").should be_nil
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns previously set state" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")

      job = service.add_job(
        name: "get_state",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "test"
      )

      state = JSON::Any.new({"temperature" => JSON::Any.new(22.5)})
      service.set_state(job.id, state)
      service.get_state(job.id).should eq(state)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
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
