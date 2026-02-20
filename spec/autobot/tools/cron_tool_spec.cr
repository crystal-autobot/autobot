require "../../spec_helper"

describe Autobot::Tools::CronTool do
  it "has correct name and description" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
    tool = Autobot::Tools::CronTool.new(service)

    tool.name.should eq("cron")
    tool.description.should_not be_empty
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  it "defines required action parameter" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
    tool = Autobot::Tools::CronTool.new(service)

    schema = tool.parameters
    schema.required.should contain("action")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end

  describe "add action" do
    it "adds a recurring job with every_seconds" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user123")

      result = tool.execute({
        "action"        => JSON::Any.new("add"),
        "message"       => JSON::Any.new("Check weather"),
        "every_seconds" => JSON::Any.new(3600_i64),
      })

      result.success?.should be_true
      result.content.should contain("Created job")
      service.list_jobs.size.should eq(1)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "adds a job with cron expression" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user123")

      result = tool.execute({
        "action"    => JSON::Any.new("add"),
        "message"   => JSON::Any.new("Morning report"),
        "cron_expr" => JSON::Any.new("0 9 * * *"),
      })

      result.success?.should be_true
      service.list_jobs.first.schedule.expr.should eq("0 9 * * *")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "adds a one-time job with at" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user123")

      result = tool.execute({
        "action"  => JSON::Any.new("add"),
        "message" => JSON::Any.new("Remind me"),
        "at"      => JSON::Any.new("2030-01-01T10:00:00Z"),
      })

      result.success?.should be_true
      service.list_jobs.first.schedule.kind.should eq(Autobot::Cron::ScheduleKind::At)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "sets owner from context" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user456")

      tool.execute({
        "action"        => JSON::Any.new("add"),
        "message"       => JSON::Any.new("Test"),
        "every_seconds" => JSON::Any.new(60_i64),
      })

      service.list_jobs.first.owner.should eq("telegram:user456")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "fails without message" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user123")

      result = tool.execute({
        "action"        => JSON::Any.new("add"),
        "every_seconds" => JSON::Any.new(60_i64),
      })

      result.success?.should be_false
      result.content.should contain("message is required")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "fails without schedule" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user123")

      result = tool.execute({
        "action"  => JSON::Any.new("add"),
        "message" => JSON::Any.new("No schedule"),
      })

      result.success?.should be_false
      result.content.should contain("every_seconds, cron_expr, or at is required")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "fails without session context" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)

      result = tool.execute({
        "action"        => JSON::Any.new("add"),
        "message"       => JSON::Any.new("No context"),
        "every_seconds" => JSON::Any.new(60_i64),
      })

      result.success?.should be_false
      result.content.should contain("no session context")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "list action" do
    it "returns empty message when no jobs" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)

      result = tool.execute({"action" => JSON::Any.new("list")})

      result.success?.should be_true
      result.content.should contain("No scheduled jobs")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "lists jobs scoped to owner" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user1")

      tool.execute({
        "action"        => JSON::Any.new("add"),
        "message"       => JSON::Any.new("User1 job"),
        "every_seconds" => JSON::Any.new(60_i64),
      })

      # Add job with different owner directly
      service.add_job(
        name: "other_user",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "Other user job",
        owner: "telegram:user2"
      )

      result = tool.execute({"action" => JSON::Any.new("list")})
      result.content.should contain("User1 job")
      result.content.should_not contain("other_user")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "remove action" do
    it "removes a job by ID" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user1")

      tool.execute({
        "action"        => JSON::Any.new("add"),
        "message"       => JSON::Any.new("To remove"),
        "every_seconds" => JSON::Any.new(60_i64),
      })

      job_id = service.list_jobs.first.id
      result = tool.execute({
        "action" => JSON::Any.new("remove"),
        "job_id" => JSON::Any.new(job_id),
      })

      result.success?.should be_true
      result.content.should contain("Removed")
      service.list_jobs.size.should eq(0)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "fails without job_id" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)

      result = tool.execute({
        "action" => JSON::Any.new("remove"),
      })

      result.success?.should be_false
      result.content.should contain("job_id is required")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "prevents removing other owner's job" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user1")

      # Add job owned by user2
      job = service.add_job(
        name: "other_job",
        schedule: Autobot::Cron::CronSchedule.new(kind: Autobot::Cron::ScheduleKind::Every, every_ms: 60000_i64),
        message: "Not yours",
        owner: "telegram:user2"
      )

      result = tool.execute({
        "action" => JSON::Any.new("remove"),
        "job_id" => JSON::Any.new(job.id),
      })

      result.success?.should be_false
      result.content.should contain("not found or access denied")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "set_state action" do
    it "sets state on a job" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)
      tool.set_context("telegram", "user1")

      tool.execute({
        "action"        => JSON::Any.new("add"),
        "message"       => JSON::Any.new("Stateful"),
        "every_seconds" => JSON::Any.new(60_i64),
      })

      job_id = service.list_jobs.first.id
      state_data = JSON::Any.new({"step_count" => JSON::Any.new(5000_i64)})

      result = tool.execute({
        "action" => JSON::Any.new("set_state"),
        "job_id" => JSON::Any.new(job_id),
        "state"  => state_data,
      })

      result.success?.should be_true
      result.content.should contain("State updated")
      service.get_state(job_id).should eq(state_data)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "fails without job_id" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)

      result = tool.execute({
        "action" => JSON::Any.new("set_state"),
        "state"  => JSON::Any.new({"key" => JSON::Any.new("val")}),
      })

      result.success?.should be_false
      result.content.should contain("job_id is required")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "fails without state" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)

      result = tool.execute({
        "action" => JSON::Any.new("set_state"),
        "job_id" => JSON::Any.new("some-id"),
      })

      result.success?.should be_false
      result.content.should contain("state is required")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "fails for nonexistent job" do
      tmp = TestHelper.tmp_dir
      service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
      tool = Autobot::Tools::CronTool.new(service)

      result = tool.execute({
        "action" => JSON::Any.new("set_state"),
        "job_id" => JSON::Any.new("nonexistent"),
        "state"  => JSON::Any.new({"key" => JSON::Any.new("val")}),
      })

      result.success?.should be_false
      result.content.should contain("not found")
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  it "returns error for unknown action" do
    tmp = TestHelper.tmp_dir
    service = Autobot::Cron::Service.new(store_path: tmp / "cron.json")
    tool = Autobot::Tools::CronTool.new(service)

    result = tool.execute({"action" => JSON::Any.new("invalid")})

    result.success?.should be_false
    result.content.should contain("Unknown action")
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end
