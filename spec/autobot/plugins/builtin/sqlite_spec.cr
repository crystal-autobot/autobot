require "../../../spec_helper"

private def create_executor(workspace : Path? = nil)
  Autobot::Tools::SandboxExecutor.new(workspace)
end

private def create_tool(workspace : Path? = nil)
  Autobot::Plugins::Builtin::SQLiteTool.new(create_executor(workspace))
end

private def json(value : String) : JSON::Any
  JSON::Any.new(value)
end

describe Autobot::Plugins::Builtin::SQLitePlugin do
  it "has correct metadata" do
    plugin = Autobot::Plugins::Builtin::SQLitePlugin.new
    plugin.name.should eq("sqlite")
    plugin.description.should_not be_empty
    plugin.version.should eq("0.1.0")
  end

  it "registers sqlite tool when sqlite3 is available" do
    plugin = Autobot::Plugins::Builtin::SQLitePlugin.new
    config = Autobot::Config::Config.new
    tool_registry = Autobot::Tools::Registry.new
    tmp = TestHelper.tmp_dir
    executor = create_executor

    context = Autobot::Plugins::PluginContext.new(
      config: config,
      tool_registry: tool_registry,
      workspace: tmp,
      sandbox_executor: executor
    )

    plugin.setup(context)

    if Process.find_executable("sqlite3")
      tool_registry.get("sqlite").should_not be_nil
    else
      tool_registry.get("sqlite").should be_nil
    end
  ensure
    FileUtils.rm_rf(tmp) if tmp
  end
end

describe Autobot::Plugins::Builtin::SQLiteTool do
  describe "#name" do
    it "returns 'sqlite'" do
      create_tool.name.should eq("sqlite")
    end
  end

  describe "#parameters" do
    it "requires action parameter" do
      tool = create_tool
      tool.parameters.required.should eq(["action"])
    end

    it "defines action, db, and query properties" do
      tool = create_tool
      props = tool.parameters.properties
      props.has_key?("action").should be_true
      props.has_key?("db").should be_true
      props.has_key?("query").should be_true
    end
  end

  describe "parameter validation" do
    it "requires db for query action" do
      tool = create_tool
      result = tool.execute({"action" => json("query")})
      result.error?.should be_true
      result.content.should contain("'db' parameter is required")
    end

    it "requires db for schema action" do
      tool = create_tool
      result = tool.execute({"action" => json("schema")})
      result.error?.should be_true
      result.content.should contain("'db' parameter is required")
    end

    it "requires db for tables action" do
      tool = create_tool
      result = tool.execute({"action" => json("tables")})
      result.error?.should be_true
      result.content.should contain("'db' parameter is required")
    end

    it "requires db for migrate action" do
      tool = create_tool
      result = tool.execute({"action" => json("migrate")})
      result.error?.should be_true
      result.content.should contain("'db' parameter is required")
    end

    it "requires query for query action" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        result = tool.execute({"action" => json("query"), "db" => json("test")})
        result.error?.should be_true
        result.content.should contain("'query' parameter is required")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "rejects invalid database names" do
      tool = create_tool
      result = tool.execute({"action" => json("tables"), "db" => json("../etc/passwd")})
      result.error?.should be_true
      result.content.should contain("Invalid database name")
    end

    it "rejects database names with dots" do
      tool = create_tool
      result = tool.execute({"action" => json("tables"), "db" => json("my.db")})
      result.error?.should be_true
      result.content.should contain("Invalid database name")
    end

    it "rejects empty database names" do
      tool = create_tool
      result = tool.execute({"action" => json("tables"), "db" => json("")})
      result.error?.should be_true
      result.content.should contain("Invalid database name")
    end

    it "accepts valid database names" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        %w[app my_db test-db data123 App].each do |name|
          result = tool.execute({"action" => json("tables"), "db" => json(name)})
          result.content.should_not contain("Invalid database name")
        end
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "databases action" do
    it "returns no databases message when data dir is empty" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        result = tool.execute({"action" => json("databases")})
        result.success?.should be_true
        result.content.should contain("No databases found")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "lists existing databases" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data")
        File.touch("data/app.db")
        File.touch("data/logs.db")
        File.touch("data/notes.txt")

        tool = create_tool
        result = tool.execute({"action" => json("databases")})
        result.success?.should be_true
        result.content.should contain("app")
        result.content.should contain("logs")
        result.content.should_not contain("notes")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "query action" do
    it "creates a table and inserts data" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO users VALUES (1, 'Alice');"),
        })

        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT * FROM users;"),
        })
        result.success?.should be_true
        result.content.should contain("Alice")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "returns results with headers" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("CREATE TABLE items (id INTEGER, name TEXT); INSERT INTO items VALUES (1, 'pen');"),
        })

        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT * FROM items;"),
        })
        result.success?.should be_true
        result.content.should contain("id")
        result.content.should contain("name")
        result.content.should contain("pen")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "auto-creates data directory" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.exists?("data").should be_false

        tool = create_tool
        tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("CREATE TABLE t (id INTEGER);"),
        })

        Dir.exists?("data").should be_true
        File.exists?("data/test.db").should be_true
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "schema action" do
    it "shows no tables message for empty database" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        result = tool.execute({"action" => json("schema"), "db" => json("empty")})
        result.success?.should be_true
        result.content.should contain("has no tables yet")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "shows CREATE TABLE statements" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT);"),
        })

        result = tool.execute({"action" => json("schema"), "db" => json("test")})
        result.success?.should be_true
        result.content.should contain("CREATE TABLE")
        result.content.should contain("users")
        result.content.should contain("name TEXT NOT NULL")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "tables action" do
    it "shows no tables message for empty database" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        result = tool.execute({"action" => json("tables"), "db" => json("empty")})
        result.success?.should be_true
        result.content.should contain("has no tables yet")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "lists table names" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("CREATE TABLE users (id INTEGER); CREATE TABLE orders (id INTEGER);"),
        })

        result = tool.execute({"action" => json("tables"), "db" => json("test")})
        result.success?.should be_true
        result.content.should contain("users")
        result.content.should contain("orders")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "migrations" do
    it "auto-applies migrations on first access" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/test")
        File.write("data/migrations/test/001_create_users.sql",
          "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);")
        File.write("data/migrations/test/002_add_email.sql",
          "ALTER TABLE users ADD COLUMN email TEXT;")

        tool = create_tool
        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');"),
        })
        result.success?.should be_true

        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT * FROM users;"),
        })
        result.success?.should be_true
        result.content.should contain("Alice")
        result.content.should contain("alice@example.com")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "tracks applied migrations in schema_migrations" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/test")
        File.write("data/migrations/test/001_init.sql", "CREATE TABLE t (id INTEGER);")

        tool = create_tool
        tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT 1;"),
        })

        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT version FROM schema_migrations;"),
        })
        result.success?.should be_true
        result.content.should contain("001_init.sql")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "skips already-applied migrations" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/test")
        File.write("data/migrations/test/001_init.sql", "CREATE TABLE t (id INTEGER);")

        tool = create_tool
        tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT 1;"),
        })

        File.write("data/migrations/test/002_add_col.sql", "ALTER TABLE t ADD COLUMN name TEXT;")

        # New tool instance to clear migration cache
        tool2 = create_tool
        tool2.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("INSERT INTO t (name) VALUES ('test');"),
        })

        result = tool2.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT version FROM schema_migrations ORDER BY version;"),
        })
        result.success?.should be_true
        result.content.should contain("001_init.sql")
        result.content.should contain("002_add_col.sql")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "uses per-database migration directories" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/app")
        Dir.mkdir_p("data/migrations/logs")
        File.write("data/migrations/app/001_users.sql", "CREATE TABLE users (id INTEGER);")
        File.write("data/migrations/logs/001_entries.sql", "CREATE TABLE entries (id INTEGER);")

        tool = create_tool

        tool.execute({"action" => json("tables"), "db" => json("app")})
        result = tool.execute({
          "action" => json("query"),
          "db"     => json("app"),
          "query"  => json("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'schema_%';"),
        })
        result.content.should contain("users")
        result.content.should_not contain("entries")

        tool.execute({"action" => json("tables"), "db" => json("logs")})
        result = tool.execute({
          "action" => json("query"),
          "db"     => json("logs"),
          "query"  => json("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'schema_%';"),
        })
        result.content.should contain("entries")
        result.content.should_not contain("users")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "works without migrations directory" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("CREATE TABLE t (id INTEGER); SELECT 1;"),
        })
        result.success?.should be_true
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "ignores non-sql files in migrations directory" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/test")
        File.write("data/migrations/test/001_init.sql", "CREATE TABLE t (id INTEGER);")
        File.write("data/migrations/test/README.md", "These are migrations")
        File.write("data/migrations/test/.gitkeep", "")

        tool = create_tool
        tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT 1;"),
        })

        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT count(*) FROM schema_migrations;"),
        })
        result.success?.should be_true
        result.content.should contain("1")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end

  describe "migrate action" do
    it "applies pending migrations and reports results" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/test")
        File.write("data/migrations/test/001_create_users.sql",
          "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);")

        tool = create_tool
        result = tool.execute({"action" => json("migrate"), "db" => json("test")})
        result.success?.should be_true
        result.content.should contain("Applied 1 migration(s)")
        result.content.should contain("001_create_users.sql")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "reports no pending migrations" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/test")
        File.write("data/migrations/test/001_init.sql", "CREATE TABLE t (id INTEGER);")

        tool = create_tool
        tool.execute({"action" => json("migrate"), "db" => json("test")})

        result = tool.execute({"action" => json("migrate"), "db" => json("test")})
        result.success?.should be_true
        result.content.should contain("up to date")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "applies new migrations added after initial access" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/test")
        File.write("data/migrations/test/001_init.sql", "CREATE TABLE t (id INTEGER);")

        tool = create_tool

        # First access triggers auto-migration
        tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT 1;"),
        })

        # Agent creates a new migration file
        File.write("data/migrations/test/002_add_name.sql",
          "ALTER TABLE t ADD COLUMN name TEXT;")

        # Explicit migrate picks up the new file (clears cache)
        result = tool.execute({"action" => json("migrate"), "db" => json("test")})
        result.success?.should be_true
        result.content.should contain("Applied 1 migration(s)")
        result.content.should contain("002_add_name.sql")

        # Verify the column exists
        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("INSERT INTO t (name) VALUES ('works');"),
        })
        result.success?.should be_true
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "reports no migrations directory gracefully" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        tool = create_tool
        result = tool.execute({"action" => json("migrate"), "db" => json("test")})
        result.success?.should be_true
        result.content.should contain("up to date")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "reports migration errors with details" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/test")
        File.write("data/migrations/test/001_good.sql", "CREATE TABLE t (id INTEGER);")
        File.write("data/migrations/test/002_bad.sql", "INVALID SQL STATEMENT;")

        tool = create_tool
        result = tool.execute({"action" => json("migrate"), "db" => json("test")})
        result.error?.should be_true
        result.content.should contain("002_bad.sql")
        result.content.should contain("failed")
        result.content.should contain("001_good.sql")

        # First migration should still have been applied and recorded
        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT version FROM schema_migrations;"),
        })
        result.content.should contain("001_good.sql")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    it "stops on first migration failure" do
      tmp = TestHelper.tmp_dir
      Dir.cd(tmp) do
        Dir.mkdir_p("data/migrations/test")
        File.write("data/migrations/test/001_good.sql", "CREATE TABLE t (id INTEGER);")
        File.write("data/migrations/test/002_bad.sql", "COMPLETELY INVALID;")
        File.write("data/migrations/test/003_also_good.sql", "CREATE TABLE t2 (id INTEGER);")

        tool = create_tool
        result = tool.execute({"action" => json("migrate"), "db" => json("test")})
        result.error?.should be_true
        result.content.should contain("002_bad.sql")

        # 003 should NOT have been applied
        result = tool.execute({
          "action" => json("query"),
          "db"     => json("test"),
          "query"  => json("SELECT name FROM sqlite_master WHERE type='table' AND name='t2';"),
        })
        result.content.should_not contain("t2")
      end
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end
  end
end
