require "../providers/provider"
require "../session/session"
require "../session/manager"
require "../constants"
require "./memory"

module Autobot::Agent
  # Manages memory consolidation for sessions.
  #
  # Responsible for:
  # - Determining when consolidation is needed
  # - Converting old messages into summarized memory
  # - Updating long-term memory and history files
  # - Trimming session messages after consolidation
  class MemoryManager
    Log = ::Log.for("agent.memory_manager")

    # Memory consolidation settings
    DISABLED_MEMORY_WINDOW             =  0 # Setting memory_window to 0 disables consolidation
    MIN_KEEP_COUNT                     =  2 # Minimum messages to keep after consolidation
    MAX_KEEP_COUNT                     = 10 # Maximum messages to keep after consolidation
    MAX_MESSAGES_WITHOUT_CONSOLIDATION = 10 # When consolidation is disabled, keep only this many messages

    def initialize(
      @workspace : Path,
      @provider : Providers::Provider,
      @model : String,
      @memory_window : Int32,
      @sessions : Session::Manager,
    )
      @memory = MemoryStore.new(@workspace)
    end

    # Check if consolidation is enabled
    def enabled? : Bool
      @memory_window != DISABLED_MEMORY_WINDOW
    end

    # Trim messages when consolidation is disabled
    def trim_if_disabled(session : Session::Session) : Nil
      return if enabled?
      return if session.messages.size <= MAX_MESSAGES_WITHOUT_CONSOLIDATION

      old_count = session.messages.size
      session.messages = session.messages[-MAX_MESSAGES_WITHOUT_CONSOLIDATION..]
      @sessions.save(session)
      Log.info { "Memory consolidation disabled - trimmed session from #{old_count} to #{session.messages.size} messages" }
    end

    # Check if session needs consolidation and perform it if necessary.
    # Runs consolidation in background to avoid blocking the agent loop.
    def consolidate_if_needed(session : Session::Session) : Nil
      return unless enabled?
      return unless needs_consolidation?(session)

      keep_count = calculate_keep_count
      old_messages = extract_old_messages(session, keep_count)
      return unless old_messages

      Log.info { "Memory consolidation: #{session.messages.size} messages, archiving #{old_messages.size}, keeping #{keep_count}" }

      conversation = format_messages(old_messages)
      current_memory = @memory.read_long_term
      prompt = build_prompt(current_memory, conversation)

      # Run consolidation in background to avoid blocking
      spawn do
        perform_consolidation(session, prompt, current_memory, keep_count)
      end
    end

    private def needs_consolidation?(session : Session::Session) : Bool
      session.messages.size > @memory_window
    end

    private def calculate_keep_count : Int32
      Math.min(MAX_KEEP_COUNT, Math.max(MIN_KEEP_COUNT, @memory_window // 2))
    end

    private def extract_old_messages(session : Session::Session, keep_count : Int32) : Array(Session::Message)?
      return nil if session.messages.size <= keep_count
      old_messages = session.messages[0..-(keep_count + 1)]
      old_messages.empty? ? nil : old_messages
    end

    private def format_messages(messages : Array(Session::Message)) : String
      lines = messages.compact_map do |message|
        next nil if message.content.empty?
        tools_str = if used_tools = message.tools_used
                      " [tools: #{used_tools.join(", ")}]"
                    else
                      ""
                    end
        "[#{message.timestamp[0, 16]}] #{message.role.upcase}#{tools_str}: #{message.content}"
      end
      lines.join("\n")
    end

    private def build_prompt(current_memory : String, conversation : String) : String
      <<-PROMPT
      You are a memory consolidation agent. Process this conversation and return a JSON object with exactly two keys:

      1. "history_entry": A paragraph (2-5 sentences) summarizing the key events/decisions/topics. Start with a timestamp like [YYYY-MM-DD HH:MM]. Include enough detail to be useful when found by grep search later.

      2. "memory_update": The updated long-term memory content. Add any new facts: user location, preferences, personal info, habits, project context, technical decisions, tools/services used. If nothing new, return the existing content unchanged.

      ## Current Long-term Memory
      #{current_memory.empty? ? "(empty)" : current_memory}

      ## Conversation to Process
      #{conversation}

      Respond with ONLY valid JSON, no markdown fences.
      PROMPT
    end

    private def perform_consolidation(
      session : Session::Session,
      prompt : String,
      current_memory : String,
      keep_count : Int32,
    ) : Nil
      response = @provider.chat(
        messages: [
          {"role" => JSON::Any.new(Constants::ROLE_SYSTEM), "content" => JSON::Any.new("You are a memory consolidation agent. Respond only with valid JSON.")},
          {"role" => JSON::Any.new(Constants::ROLE_USER), "content" => JSON::Any.new(prompt)},
        ],
        model: @model
      )

      result = parse_result((response.content || "").strip)
      apply_result(result, current_memory)
      trim_session(session, keep_count)
    rescue ex
      Log.error { "Memory consolidation failed: #{ex.message}" }
    end

    private def parse_result(text : String) : JSON::Any
      cleaned = strip_markdown_code_fence(text)
      JSON.parse(cleaned)
    end

    private def strip_markdown_code_fence(text : String) : String
      return text unless text.starts_with?("```")

      parts = text.split("\n", 2)
      return text if parts.size <= 1

      code_parts = parts[1].split("```")
      return text if code_parts.empty?

      code_parts[0].strip
    end

    private def apply_result(result : JSON::Any, current_memory : String) : Nil
      # Extract history_entry (string or convert from hash)
      if entry_json = result["history_entry"]?
        entry = entry_json.as_s? || entry_json.to_json
        @memory.append_history(entry) unless entry.empty?
      end

      # Extract memory_update (string or convert from hash)
      if update_json = result["memory_update"]?
        update = update_json.as_s? || update_json.to_json
        @memory.write_long_term(update) if update != current_memory
      end
    end

    private def trim_session(session : Session::Session, keep_count : Int32) : Nil
      session.messages = session.messages[-keep_count..]
      @sessions.save(session)
      Log.info { "Memory consolidation done, session trimmed to #{session.messages.size} messages" }
    end
  end
end
