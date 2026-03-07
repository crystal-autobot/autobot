require "../plugin"
require "../../tools/result"

module Autobot
  module Plugins
    module Builtin
      # SQLite plugin for persistent structured data storage.
      #
      # Provides a unified tool for managing SQLite databases with
      # automatic migration support. Requires the `sqlite3` CLI.
      class SQLitePlugin < Plugin
        def name : String
          "sqlite"
        end

        def description : String
          "Persistent structured data storage with SQLite"
        end

        def version : String
          "0.1.0"
        end

        def setup(context : PluginContext) : Nil
          unless Process.find_executable("sqlite3")
            Log.warn { "SQLite plugin: 'sqlite3' CLI not found, skipping tool registration" }
            return
          end

          context.tool_registry.register(SQLiteTool.new(context.sandbox_executor))
        end
      end

      # Unified SQLite tool for database operations.
      #
      # Databases are stored as `data/{name}.db`. Per-database migrations
      # live in `data/migrations/{name}/` and are auto-applied on first access.
      class SQLiteTool < Tools::Tool
        Log = ::Log.for("sqlite")

        DB_DIR            = "data"
        QUERY_TIMEOUT     = 30
        SCHEMA_TIMEOUT    = 10
        MIGRATION_TIMEOUT = 30
        INIT_TIMEOUT      = 10

        VALID_DB_NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/
        ACTIONS       = ["query", "schema", "tables", "databases", "migrate"]

        def initialize(@executor : Tools::SandboxExecutor)
          @migrated_dbs = Set(String).new
        end

        def name : String
          "sqlite"
        end

        def description : String
          "Manage SQLite databases for structured data storage. " \
          "Databases are stored as data/{name}.db. " \
          "Migrations from data/migrations/{name}/*.sql are auto-applied on first access. " \
          "Actions: query (execute SQL), schema (show CREATE statements), " \
          "tables (list table names), databases (list available databases), " \
          "migrate (apply pending migrations — use after creating new migration files)."
        end

        def parameters : Tools::ToolSchema
          Tools::ToolSchema.new(
            properties: {
              "action" => Tools::PropertySchema.new(
                type: "string",
                description: "Action to perform",
                enum_values: ACTIONS
              ),
              "db" => Tools::PropertySchema.new(
                type: "string",
                description: "Database name (e.g. 'app' for data/app.db). Required for query/schema/tables/migrate."
              ),
              "query" => Tools::PropertySchema.new(
                type: "string",
                description: "SQL to execute. Required for action=query."
              ),
            },
            required: ["action"]
          )
        end

        def execute(params : Hash(String, JSON::Any)) : Tools::ToolResult
          action = params["action"].as_s
          return list_databases if action == "databases"

          db_name = params["db"]?.try(&.as_s)
          return Tools::ToolResult.error("'db' parameter is required for action '#{action}'") unless db_name

          error = validate_db_name(db_name)
          return error if error

          ensure_data_dir
          dispatch_action(action, db_name, params)
        end

        private def dispatch_action(action : String, db_name : String, params : Hash(String, JSON::Any)) : Tools::ToolResult
          case action
          when "migrate" then run_migrate(db_name)
          when "query"   then auto_migrate_and(db_name) { execute_query(db_name, params) }
          when "schema"  then auto_migrate_and(db_name) { show_schema(db_name) }
          when "tables"  then auto_migrate_and(db_name) { list_tables(db_name) }
          else                Tools::ToolResult.error("Unknown action: #{action}")
          end
        end

        # -- Validation & setup ------------------------------------------------

        private def validate_db_name(name : String) : Tools::ToolResult?
          return if name.matches?(VALID_DB_NAME)

          Tools::ToolResult.error(
            "Invalid database name '#{name}'. Use only letters, numbers, underscores, and hyphens."
          )
        end

        private def ensure_data_dir : Nil
          @executor.exec("mkdir -p #{shell_escape(DB_DIR)}", timeout: INIT_TIMEOUT)
        end

        private def db_path(db_name : String) : String
          "#{DB_DIR}/#{db_name}.db"
        end

        private def migrations_dir(db_name : String) : String
          "#{DB_DIR}/migrations/#{db_name}"
        end

        # -- Migration ---------------------------------------------------------

        private def run_migrate(db_name : String) : Tools::ToolResult
          @migrated_dbs.delete(db_name)
          result = apply_pending_migrations(db_name)
          # Always mark as migrated so queries aren't blocked by bad migrations.
          # The agent can fix the migration file and call migrate again.
          @migrated_dbs.add(db_name)
          result
        end

        private def auto_migrate_and(db_name : String, &) : Tools::ToolResult
          unless @migrated_dbs.includes?(db_name)
            result = apply_pending_migrations(db_name)
            return result if result.error?
            @migrated_dbs.add(db_name)
          end
          yield
        end

        private def apply_pending_migrations(db_name : String) : Tools::ToolResult
          pending = find_pending_migrations(db_name)
          return pending if pending.is_a?(Tools::ToolResult)
          return Tools::ToolResult.success("All migrations are up to date.") if pending.empty?

          apply_migration_batch(db_name, pending)
        end

        private def find_pending_migrations(db_name : String) : Array(String) | Tools::ToolResult
          dir = migrations_dir(db_name)
          list_result = @executor.list_dir(dir)
          return [] of String unless list_result.success?

          files = list_result.content.split("\n")
            .reject(&.empty?)
            .select(&.ends_with?(".sql"))
            .sort!
          return [] of String if files.empty?

          init_result = init_migrations_table(db_name)
          return init_result if command_failed?(init_result)

          applied = get_applied_migrations(db_name)
          files.reject { |file| applied.includes?(file) }
        end

        private def apply_migration_batch(db_name : String, pending : Array(String)) : Tools::ToolResult
          dir = migrations_dir(db_name)
          applied_now = [] of String

          pending.each do |file|
            result = apply_single_migration(db_name, dir, file)
            unless result.success?
              return migration_error(file, result.content, applied_now)
            end
            applied_now << file
          end

          message = "Applied #{applied_now.size} migration(s): #{applied_now.join(", ")}"
          Log.info { "#{db_name}: #{message}" }
          Tools::ToolResult.success(message)
        end

        private def migration_error(file : String, error : String, applied_so_far : Array(String)) : Tools::ToolResult
          parts = ["Migration '#{file}' failed: #{error}"]
          parts << "Previously applied in this batch: #{applied_so_far.join(", ")}" unless applied_so_far.empty?
          Tools::ToolResult.error(parts.join("\n"))
        end

        private def init_migrations_table(db_name : String) : Tools::ToolResult
          sql = "CREATE TABLE IF NOT EXISTS schema_migrations " \
                "(version TEXT PRIMARY KEY, applied_at DATETIME DEFAULT CURRENT_TIMESTAMP);"
          @executor.exec("sqlite3 #{shell_escape(db_path(db_name))} #{shell_escape(sql)}", timeout: INIT_TIMEOUT)
        end

        private def get_applied_migrations(db_name : String) : Array(String)
          result = @executor.exec(
            "sqlite3 #{shell_escape(db_path(db_name))} #{shell_escape("SELECT version FROM schema_migrations ORDER BY version;")}",
            timeout: SCHEMA_TIMEOUT
          )
          return [] of String if command_failed?(result)

          result.content.split("\n").reject(&.empty?)
        end

        private def apply_single_migration(db_name : String, dir : String, file : String) : Tools::ToolResult
          path = db_path(db_name)
          migration_path = "#{dir}/#{file}"

          apply_result = @executor.exec(
            "sqlite3 #{shell_escape(path)} < #{shell_escape(migration_path)}",
            timeout: MIGRATION_TIMEOUT
          )

          if command_failed?(apply_result)
            return Tools::ToolResult.error(apply_result.content)
          end

          record_sql = "INSERT INTO schema_migrations (version) VALUES (#{shell_escape(file)});"
          record_result = @executor.exec(
            "sqlite3 #{shell_escape(path)} #{shell_escape(record_sql)}",
            timeout: INIT_TIMEOUT
          )

          if command_failed?(record_result)
            return Tools::ToolResult.error("Migration applied but failed to record: #{record_result.content}")
          end

          Tools::ToolResult.success("Applied: #{file}")
        end

        # -- Query -------------------------------------------------------------

        private def execute_query(db_name : String, params : Hash(String, JSON::Any)) : Tools::ToolResult
          query = params["query"]?.try(&.as_s)
          return Tools::ToolResult.error("'query' parameter is required for action 'query'") unless query

          @executor.exec(
            "sqlite3 -header -column #{shell_escape(db_path(db_name))} #{shell_escape(query)}",
            timeout: QUERY_TIMEOUT
          )
        end

        # -- Introspection -----------------------------------------------------

        private def show_schema(db_name : String) : Tools::ToolResult
          result = @executor.exec(
            "sqlite3 #{shell_escape(db_path(db_name))} '.schema'",
            timeout: SCHEMA_TIMEOUT
          )
          return result unless result.success?

          empty_output?(result.content) ? no_tables_message(db_name) : result
        end

        private def list_tables(db_name : String) : Tools::ToolResult
          result = @executor.exec(
            "sqlite3 #{shell_escape(db_path(db_name))} '.tables'",
            timeout: SCHEMA_TIMEOUT
          )
          return result unless result.success?

          empty_output?(result.content) ? no_tables_message(db_name) : result
        end

        private def list_databases : Tools::ToolResult
          list_result = @executor.list_dir(DB_DIR)

          unless list_result.success?
            return Tools::ToolResult.success("No databases found. Use action='query' to create one.")
          end

          db_files = list_result.content.split("\n")
            .reject(&.empty?)
            .select(&.ends_with?(".db"))
            .map(&.chomp(".db"))
            .sort!

          if db_files.empty?
            Tools::ToolResult.success("No databases found. Use action='query' to create one.")
          else
            Tools::ToolResult.success(db_files.join("\n"))
          end
        end

        # -- Helpers -----------------------------------------------------------

        # SandboxExecutor.exec always returns ToolResult.success, even for failed
        # commands. Detect actual failures by checking for stderr output (the
        # executor wraps it as "STDERR:\n...") or non-zero exit codes reported
        # by the sandbox. Any stderr from sqlite3 indicates an error.
        private def command_failed?(result : Tools::ToolResult) : Bool
          return true if result.error?

          content = result.content
          content.includes?("STDERR:") || content.includes?("Exit code:")
        end

        private def empty_output?(content : String) : Bool
          stripped = content.strip
          stripped.empty? || stripped == "[no output]"
        end

        private def no_tables_message(db_name : String) : Tools::ToolResult
          Tools::ToolResult.success("Database '#{db_name}' has no tables yet.")
        end

        private def shell_escape(arg : String) : String
          "'#{arg.gsub("'", "'\\''")}'"
        end
      end
    end
  end
end
