require "../bus/events"
require "../providers/types"
require "../constants"
require "./memory"
require "./skills"

module Autobot::Agent
  module Context
    # Builds LLM context from skills, memory, history, and current message.
    #
    # Assembles bootstrap files, memory, skills, and conversation history
    # into a coherent prompt for the LLM.
    class Builder
      BOOTSTRAP_FILES  = ["AGENTS.md", "SOUL.md", "USER.md", "TOOLS.md", "IDENTITY.md"]
      TIMESTAMP_FORMAT = "%Y-%m-%d %H:%M (%A)"

      @workspace : Path
      @memory : MemoryStore
      @skills : SkillsLoader
      @sandboxed : Bool

      def initialize(@workspace : Path, @sandboxed : Bool = false)
        @memory = MemoryStore.new(@workspace)
        @skills = SkillsLoader.new(@workspace)
      end

      # Build complete message array for LLM
      def build_messages(
        history : Array(Hash(String, String)),
        current_message : String,
        media : Array(Bus::MediaAttachment)? = nil,
        channel : String? = nil,
        chat_id : String? = nil,
      ) : Array(Hash(String, JSON::Any))
        messages = [] of Hash(String, JSON::Any)

        # Build system prompt with memory + skills
        system_prompt = build_system_prompt
        if channel && chat_id
          system_prompt += "\n\n## Current Session\nChannel: #{channel}\nChat ID: #{chat_id}"
        end

        messages << {
          "role"    => JSON::Any.new(Constants::ROLE_SYSTEM),
          "content" => JSON::Any.new(system_prompt),
        }

        # Add conversation history
        history.each do |msg|
          messages << {
            "role"    => JSON::Any.new(msg["role"]),
            "content" => JSON::Any.new(msg["content"]),
          }
        end

        # Add current user message
        content = current_message
        if media && !media.empty?
          media_info = media.map { |media_item| "[#{media_item.type}: #{media_item.file_path || media_item.url}]" }.join("\n")
          content = "#{content}\n\nMedia:\n#{media_info}"
        end

        messages << {
          "role"    => JSON::Any.new(Constants::ROLE_USER),
          "content" => JSON::Any.new(content),
        }

        messages
      end

      # Add assistant message with tool calls
      def add_assistant_message(
        messages : Array(Hash(String, JSON::Any)),
        content : String?,
        tool_calls : Array(Providers::ToolCall),
        reasoning_content : String? = nil,
      ) : Array(Hash(String, JSON::Any))
        tool_call_data = tool_calls.map do |tool_call|
          JSON::Any.new({
            "id"       => JSON::Any.new(tool_call.id),
            "type"     => JSON::Any.new("function"),
            "function" => JSON::Any.new({
              "name"      => JSON::Any.new(tool_call.name),
              "arguments" => JSON::Any.new(tool_call.arguments.to_json),
            }),
          })
        end

        msg = {
          "role"       => JSON::Any.new(Constants::ROLE_ASSISTANT),
          "content"    => JSON::Any.new(content || ""),
          "tool_calls" => JSON::Any.new(tool_call_data),
        }

        if rc = reasoning_content
          msg["reasoning_content"] = JSON::Any.new(rc)
        end

        messages << msg
        messages
      end

      # Add tool result message
      def add_tool_result(
        messages : Array(Hash(String, JSON::Any)),
        tool_call_id : String,
        tool_name : String,
        result : String,
      ) : Array(Hash(String, JSON::Any))
        messages << {
          "role"         => JSON::Any.new(Constants::ROLE_TOOL),
          "tool_call_id" => JSON::Any.new(tool_call_id),
          "name"         => JSON::Any.new(tool_name),
          "content"      => JSON::Any.new(result),
        }

        messages
      end

      # Build the complete system prompt from identity, bootstrap files, memory, and skills.
      private def build_system_prompt : String
        parts = [] of String

        parts << identity_section

        bootstrap = load_bootstrap_files
        parts << bootstrap unless bootstrap.empty?

        # Memory context
        memory_ctx = @memory.memory_context
        parts << "# Memory\n\n#{memory_ctx}" unless memory_ctx.empty?

        # Always-loaded skills: include full content
        always_skills = @skills.always_skills
        unless always_skills.empty?
          always_content = @skills.load_skills_for_context(always_skills)
          parts << "# Active Skills\n\n#{always_content}" unless always_content.empty?
        end

        # Available skills: show summary for progressive loading
        skills_summary = @skills.build_skills_summary
        unless skills_summary.empty?
          parts << <<-SKILLS
          # Skills

          The following skills extend your capabilities. To use a skill, read its SKILL.md file using the read_file tool.
          Skills with available="false" need dependencies installed first.

          #{skills_summary}
          SKILLS
        end

        parts.join("\n\n---\n\n")
      end

      private def build_security_policy(workspace_path : String) : String
        return "" unless @sandboxed

        <<-POLICY


        ## Security Policy
        Sandboxing is ENABLED. All file and command operations are restricted to: #{workspace_path}

        **File paths must be workspace-relative:**
        - ❌ Absolute paths (e.g. /etc/passwd) — blocked by sandbox
        - ❌ Parent traversal (e.g. ../outside/file.txt) — blocked by sandbox

        When a tool returns an error due to sandbox restrictions:
        1. Inform the user clearly: "I cannot do that - sandboxing restricts me to #{workspace_path}"
        2. Do not attempt workarounds or alternatives that bypass restrictions

        Sandbox-enforced restrictions:
        - File operations outside workspace will fail (kernel-enforced)
        - Dangerous command patterns are blocked (rm -rf, curl | bash, etc.)
        - SSRF attempts are blocked (private IPs, cloud metadata)
        POLICY
      end

      private def identity_section : String
        now = Time.utc.to_s(TIMESTAMP_FORMAT)
        workspace_path = @workspace.expand(home: true).to_s

        <<-IDENTITY
        # autobot

        You are Autobot, an AI agent powered by Crystal - fast, type-safe, and extensible.

        You have access to tools that allow you to:
        - Read, write, and edit files
        - Execute shell commands
        - Search the web and fetch web pages
        - Send messages to users on chat channels
        - Spawn subagents for complex background tasks
        - Schedule cron jobs for reminders and recurring tasks

        ## Current Time
        #{now} (UTC)

        ## Workspace
        Your workspace is at: #{workspace_path}

        Use relative paths for workspace files:
        - read_file("memory/MEMORY.md")
        - write_file("skills/my_tool/tool.sh", content)

        Important workspace files:
        - Long-term memory: memory/MEMORY.md
        - History log: memory/HISTORY.md (grep-searchable)
        - Custom skills: skills/{skill-name}/SKILL.md

        #{build_security_policy(workspace_path)}
        IMPORTANT: When responding to direct questions or conversations, reply directly with your text response.
        Only use the 'message' tool when you need to send a message to a specific chat channel.
        For normal conversation, just respond with text - do not call the message tool.

        Always be helpful, accurate, and concise. When using tools, think step by step.
        When remembering something important, write to memory/MEMORY.md
        To recall past events, grep memory/HISTORY.md
        IDENTITY
      end

      private def load_bootstrap_files : String
        parts = [] of String

        BOOTSTRAP_FILES.each do |filename|
          file_path = @workspace / filename
          if File.exists?(file_path)
            content = File.read(file_path)
            parts << "## #{filename}\n\n#{content}"
          end
        end

        parts.join("\n\n")
      end
    end
  end
end
