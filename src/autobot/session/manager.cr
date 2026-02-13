require "json"
require "./session"

module Autobot
  module Session
    # Manages conversation sessions with JSONL file persistence.
    class Manager
      @sessions_dir : Path
      @cache : Hash(String, Session) = {} of String => Session

      def initialize(workspace : Path)
        @sessions_dir = workspace / "sessions"
        Dir.mkdir_p(@sessions_dir) unless Dir.exists?(@sessions_dir)
      end

      # Get an existing session or create a new one.
      def get_or_create(key : String) : Session
        if session = @cache[key]?
          return session
        end

        session = load(key) || Session.new(key: key)
        @cache[key] = session
        session
      end

      # Save a session to disk as JSONL.
      def save(session : Session) : Nil
        path = session_path(session.key)

        # Ensure sessions directory exists with restrictive permissions
        Dir.mkdir_p(@sessions_dir) unless Dir.exists?(@sessions_dir)
        File.chmod(@sessions_dir, 0o700)

        File.open(path, "w") do |session_file|
          meta = Metadata.new(
            created_at: session.created_at.to_rfc3339,
            updated_at: session.updated_at.to_rfc3339,
            metadata: session.metadata
          )
          session_file.puts(meta.to_json)

          session.messages.each do |msg|
            session_file.puts(msg.to_json)
          end
        end

        # Set restrictive permissions on session file (user read/write only)
        File.chmod(path, 0o600)

        @cache[session.key] = session
      end

      # Delete a session.
      def delete(key : String) : Bool
        @cache.delete(key)

        path = session_path(key)
        if File.exists?(path)
          File.delete(path)
          true
        else
          false
        end
      end

      # List all sessions with metadata.
      def list_sessions : Array(Hash(String, String))
        sessions = [] of Hash(String, String)

        Dir.glob(File.join(@sessions_dir, "*.jsonl")) do |path|
          begin
            first_line = File.open(path, &.gets)
            next unless first_line

            data = JSON.parse(first_line)
            next unless data["_type"]?.try(&.as_s) == "metadata"

            sessions << {
              "key"        => Path[path].stem.gsub("_", ":"),
              "created_at" => data["created_at"]?.try(&.as_s) || "",
              "updated_at" => data["updated_at"]?.try(&.as_s) || "",
              "path"       => path,
            }
          rescue
            next
          end
        end

        sessions.sort_by { |session_data| session_data["updated_at"] }.reverse!
      end

      private def session_path(key : String) : String
        safe_key = safe_filename(key.gsub(":", "_"))
        File.join(@sessions_dir, "#{safe_key}.jsonl")
      end

      private def safe_filename(name : String) : String
        name.gsub(/[^\w\-.]/, "_")
      end

      private def load(key : String) : Session?
        path = session_path(key)
        return nil unless File.exists?(path)

        begin
          messages = [] of Message
          meta_hash = {} of String => JSON::Any
          created_at : Time? = nil

          File.each_line(path) do |line|
            line = line.strip
            next if line.empty?

            data = JSON.parse(line)

            if data["_type"]?.try(&.as_s) == "metadata"
              if ca = data["created_at"]?.try(&.as_s)
                created_at = Time.parse_rfc3339(ca)
              end
              if md = data["metadata"]?
                md.as_h.each { |k, v| meta_hash[k] = v }
              end
            else
              messages << Message.from_json(line)
            end
          end

          Session.new(
            key: key,
            messages: messages,
            created_at: created_at || Time.utc,
            metadata: meta_hash
          )
        rescue ex
          Log.warn { "Failed to load session #{key}: #{ex.message}" }
          nil
        end
      end
    end
  end
end
