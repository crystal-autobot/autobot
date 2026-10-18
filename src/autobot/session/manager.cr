require "json"
require "./session"

module Autobot
  module Session
    # Manages conversation sessions with JSONL file persistence.
    class Manager
      getter sessions_dir : Path
      @cache : Hash(String, Session) = {} of String => Session
      @file_states : Hash(String, {Time, Int64}) = {} of String => {Time, Int64}
      @loaded_counts : Hash(String, Int32) = {} of String => Int32

      def initialize(workspace : Path)
        @sessions_dir = workspace / "sessions"
        Dir.mkdir_p(@sessions_dir) unless Dir.exists?(@sessions_dir)
      end

      # Get an existing session or create a new one.
      # Reloads from disk if the session file was modified externally (e.g. by CLI).
      def get_or_create(key : String) : Session
        if (session = @cache[key]?) && !changed_on_disk?(key)
          return session
        end

        session = load(key) || Session.new(key: key)
        @cache[key] = session
        @loaded_counts[key] = session.messages.size
        session
      end

      # Save a session to disk as JSONL.
      def save(session : Session) : Nil
        key = session.key
        path = session_path(key)

        if changed_on_disk?(key)
          merge_disk_changes(session)
        end

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

        record_file_state(key, path, session.messages.size)
        @cache[key] = session
      end

      # Delete a session.
      def delete(key : String) : Bool
        @cache.delete(key)
        @file_states.delete(key)
        @loaded_counts.delete(key)

        path = session_path(key)
        if File.exists?(path)
          File.delete(path)
          true
        else
          false
        end
      end

      private def session_path(key : String) : String
        safe_key = safe_filename(key.gsub(":", "_"))
        File.join(@sessions_dir, "#{safe_key}.jsonl")
      end

      private def safe_filename(name : String) : String
        name.gsub(/[^\w\-.]/, "_")
      end

      private def file_state(path : String) : {Time, Int64}?
        return nil unless File.exists?(path)
        info = File.info(path)
        {info.modification_time, info.size}
      rescue
        nil
      end

      private def changed_on_disk?(key : String) : Bool
        file_state(session_path(key)) != @file_states[key]?
      end

      private def record_file_state(key : String, path : String, count : Int32) : Nil
        if state = file_state(path)
          @file_states[key] = state
        else
          @file_states.delete(key)
        end
        @loaded_counts[key] = count
      end

      private def merge_disk_changes(session : Session) : Nil
        key = session.key
        return unless disk_session = load(key)

        base_count = @loaded_counts[key]? || 0
        added = base_count < session.messages.size ? session.messages[base_count..] : [] of Message
        session.messages.clear
        session.messages.concat(disk_session.messages)
        session.messages.concat(added)
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

          loaded = Session.new(
            key: key,
            messages: messages,
            created_at: created_at || Time.utc,
            metadata: meta_hash
          )
          record_file_state(key, path, messages.size)
          loaded
        rescue ex
          Log.warn { "Failed to load session #{key}: #{ex.message}" }
          nil
        end
      end
    end
  end
end
