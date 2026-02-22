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

      # Build complete message array for LLM.
      # When `background` is true, uses a minimal system prompt (no formatting rules,
      # skills summary, or session info) to reduce token usage for background tasks.
      def build_messages(
        history : Array(Hash(String, String)),
        current_message : String,
        media : Array(Bus::MediaAttachment)? = nil,
        channel : String? = nil,
        chat_id : String? = nil,
        background : Bool = false,
        tool_names : Array(String)? = nil,
      ) : Array(Hash(String, JSON::Any))
        messages = [] of Hash(String, JSON::Any)

        system_prompt = build_system_prompt(background, tool_names)
        unless background
          if channel && chat_id
            system_prompt += "\n\n## Current Session\nChannel: #{channel}\nChat ID: #{chat_id}"
          end
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
        messages << {
          "role"    => JSON::Any.new(Constants::ROLE_USER),
          "content" => build_user_content(current_message, media),
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
          data = {
            "id"       => JSON::Any.new(tool_call.id),
            "type"     => JSON::Any.new("function"),
            "function" => JSON::Any.new({
              "name"      => JSON::Any.new(tool_call.name),
              "arguments" => JSON::Any.new(tool_call.arguments.to_json),
            }),
          } of String => JSON::Any

          if extra_content = tool_call.extra_content
            data["extra_content"] = extra_content
          end

          JSON::Any.new(data)
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
      # When `background` is true, uses minimal identity and skips skills summary.
      private def build_system_prompt(background : Bool = false, tool_names : Array(String)? = nil) : String
        parts = [] of String

        parts << (background ? background_identity_section : identity_section)

        bootstrap = load_bootstrap_files
        parts << bootstrap unless bootstrap.empty?

        # Memory context
        memory_ctx = @memory.memory_context
        parts << "# Memory\n\n#{memory_ctx}" unless memory_ctx.empty?

        # Auto-loaded skills: always=true + tool-linked skills
        auto_skills = @skills.always_skills
        if tool_names && !tool_names.empty?
          auto_skills.concat(@skills.tool_skills(tool_names))
          auto_skills.uniq!
        end

        unless auto_skills.empty?
          auto_content = @skills.load_skills_for_context(auto_skills)
          parts << "# Active Skills\n\n#{auto_content}" unless auto_content.empty?
        end

        # Available skills: show summary for progressive loading (skip for background)
        unless background
          skills_summary = @skills.build_skills_summary
          unless skills_summary.empty?
            parts << <<-SKILLS
            # Skills

            The following skills extend your capabilities. To use a skill, read its SKILL.md file using the read_file tool.
            Skills with available="false" need dependencies installed first.

            #{skills_summary}
            SKILLS
          end
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

      # Minimal identity for background tasks (cron turns, subagent work).
      # Keeps: time, workspace, security. Drops: formatting, conversation rules, skills hints.
      private def background_identity_section : String
        now = Time.utc.to_s(TIMESTAMP_FORMAT)
        workspace_path = @workspace.expand(home: true).to_s

        <<-IDENTITY
        # autobot (background task)

        You are Autobot, executing a scheduled background task.
        Current time: #{now} (UTC)
        Workspace: #{workspace_path}
        #{build_security_policy(workspace_path)}
        IDENTITY
      end

      private def identity_section : String
        now = Time.utc.to_s(TIMESTAMP_FORMAT)
        workspace_path = @workspace.expand(home: true).to_s

        <<-IDENTITY
        # autobot

        You are Autobot, an AI agent. Time: #{now} (UTC). Workspace: #{workspace_path}

        Key files: memory/MEMORY.md (long-term), memory/HISTORY.md (grep-searchable log), skills/*/SKILL.md
        #{build_security_policy(workspace_path)}
        Rules:
        - Use relative paths for workspace files
        - Reply with text for conversations; use 'message' tool only for chat channels
        - Use `cron` for delayed tasks (never `exec sleep`)
        - Batch independent tool calls in a single response to reduce round-trips
        - Use simple Markdown: **bold**, `code`, _italic_, bullet lists
        - Be helpful, accurate, and concise
        IDENTITY
      end

      private def build_user_content(text : String, media : Array(Bus::MediaAttachment)?) : JSON::Any
        if media && media.any?(&.data)
          return build_multimodal_content(text, media)
        end

        content = text
        if media && !media.empty?
          media_info = media.map { |attachment| "[#{attachment.type}: #{attachment.file_path || attachment.url}]" }.join("\n")
          content = "#{content}\n\nMedia:\n#{media_info}"
        end
        JSON::Any.new(content)
      end

      private def build_multimodal_content(text : String, media : Array(Bus::MediaAttachment)) : JSON::Any
        blocks = [] of JSON::Any

        blocks << JSON::Any.new({
          "type" => JSON::Any.new("text"),
          "text" => JSON::Any.new(text),
        } of String => JSON::Any) unless text.empty?

        media.each do |attachment|
          if image_data = attachment.data
            blocks << build_image_block(image_data, attachment.mime_type || "image/jpeg")
          end
        end

        JSON::Any.new(blocks)
      end

      private def build_image_block(data : String, mime_type : String) : JSON::Any
        JSON::Any.new({
          "type"      => JSON::Any.new("image_url"),
          "image_url" => JSON::Any.new({
            "url" => JSON::Any.new("data:#{mime_type};base64,#{data}"),
          } of String => JSON::Any),
        } of String => JSON::Any)
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
