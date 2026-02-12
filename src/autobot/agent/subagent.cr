require "json"
require "uuid"
require "../bus/events"
require "../bus/queue"
require "../providers/provider"
require "../providers/types"
require "../tools/registry"
require "../tools/filesystem"
require "../tools/exec"
require "../tools/web"

module Autobot
  module Agent
    # Manages background subagent execution.
    #
    # Subagents are lightweight agent instances that run in background fibers
    # to handle specific tasks. They share the same LLM provider but have
    # isolated context and a focused system prompt.
    class SubagentManager
      Log = ::Log.for("subagent")

      MAX_ITERATIONS = 15

      @provider : Providers::Provider
      @workspace : Path
      @bus : Bus::MessageBus
      @model : String?
      @brave_api_key : String?
      @exec_timeout : Int32
      @restrict_to_workspace : Bool
      @running_tasks : Hash(String, Bool) = {} of String => Bool

      def initialize(
        @provider : Providers::Provider,
        @workspace : Path,
        @bus : Bus::MessageBus,
        @model : String? = nil,
        @brave_api_key : String? = nil,
        @exec_timeout : Int32 = 60,
        @restrict_to_workspace : Bool = false,
      )
      end

      # Spawn a subagent to execute a task in the background.
      def spawn(
        task : String,
        label : String? = nil,
        origin_channel : String = "cli",
        origin_chat_id : String = "direct",
      ) : String
        task_id = UUID.random.to_s[0, 8]
        display_label = label || (task.size > 30 ? task[0, 30] + "..." : task)

        origin = {"channel" => origin_channel, "chat_id" => origin_chat_id}

        @running_tasks[task_id] = true

        ::spawn do
          run_subagent(task_id, task, display_label, origin)
          @running_tasks.delete(task_id)
        end

        Log.info { "Spawned subagent [#{task_id}]: #{display_label}" }
        "Subagent [#{display_label}] started (id: #{task_id}). I'll notify you when it completes."
      end

      # Return the number of currently running subagents.
      def running_count : Int32
        @running_tasks.size
      end

      private def run_subagent(
        task_id : String,
        task : String,
        label : String,
        origin : Hash(String, String),
      ) : Nil
        Log.info { "Subagent [#{task_id}] starting task: #{label}" }

        begin
          # Build isolated tool registry (no message or spawn tools)
          tools = Tools::Registry.new
          allowed_dir = @restrict_to_workspace ? @workspace : nil
          tools.register(Tools::ReadFileTool.new(allowed_dir: allowed_dir))
          tools.register(Tools::WriteFileTool.new(allowed_dir: allowed_dir))
          tools.register(Tools::EditFileTool.new(allowed_dir: allowed_dir))
          tools.register(Tools::ListDirTool.new(allowed_dir: allowed_dir))
          tools.register(Tools::ExecTool.new(
            working_dir: @workspace.to_s,
            timeout: @exec_timeout,
            restrict_to_workspace: @restrict_to_workspace
          ))
          tools.register(Tools::WebSearchTool.new(api_key: @brave_api_key))
          tools.register(Tools::WebFetchTool.new)

          # Build messages with subagent-specific prompt
          system_prompt = build_subagent_prompt(task)
          messages = [
            build_message("system", system_prompt),
            build_message("user", task),
          ]

          # Run agent loop (limited iterations)
          final_result : String? = nil

          MAX_ITERATIONS.times do |_|
            response = @provider.chat(
              messages: messages,
              tools: tools.definitions,
              model: @model
            )

            if response.has_tool_calls?
              # Add assistant message with tool calls
              tool_call_dicts = response.tool_calls.map do |tool_call|
                JSON::Any.new({
                  "id"       => JSON::Any.new(tool_call.id),
                  "type"     => JSON::Any.new("function"),
                  "function" => JSON::Any.new({
                    "name"      => JSON::Any.new(tool_call.name),
                    "arguments" => JSON::Any.new(tool_call.arguments.to_json),
                  }),
                })
              end

              messages << build_message_with_tools("assistant", response.content || "", tool_call_dicts)

              # Execute tools
              response.tool_calls.each do |tool_call|
                Log.debug { "Subagent [#{task_id}] executing: #{tool_call.name}" }
                result = tools.execute(tool_call.name, tool_call.arguments)
                messages << build_tool_result(tool_call.id, tool_call.name, result)
              end
            else
              final_result = response.content
              break
            end
          end

          final_result ||= "Task completed but no final response was generated."

          Log.info { "Subagent [#{task_id}] completed successfully" }
          announce_result(task_id, label, task, final_result, origin, "ok")
        rescue ex
          error_msg = "Error: #{ex.message}"
          Log.error { "Subagent [#{task_id}] failed: #{ex.message}" }
          announce_result(task_id, label, task, error_msg, origin, "error")
        end
      end

      private def announce_result(
        task_id : String,
        label : String,
        task : String,
        result : String,
        origin : Hash(String, String),
        status : String,
      ) : Nil
        status_text = status == "ok" ? "completed successfully" : "failed"

        announce_content = <<-CONTENT
        [Subagent '#{label}' #{status_text}]

        Task: #{task}

        Result:
        #{result}

        Summarize this naturally for the user. Keep it brief (1-2 sentences). Do not mention technical details like "subagent" or task IDs.
        CONTENT

        msg = Bus::InboundMessage.new(
          channel: "system",
          sender_id: "subagent",
          chat_id: "#{origin["channel"]}:#{origin["chat_id"]}",
          content: announce_content
        )

        @bus.publish_inbound(msg)
        Log.debug { "Subagent [#{task_id}] announced result to #{origin["channel"]}:#{origin["chat_id"]}" }
      end

      private def build_subagent_prompt(task : String) : String
        now = Time.utc.to_s("%Y-%m-%d %H:%M (%A)")

        <<-PROMPT
        # Subagent

        ## Current Time
        #{now} (UTC)

        You are a subagent spawned by the main agent to complete a specific task.

        ## Rules
        1. Stay focused - complete only the assigned task, nothing else
        2. Your final response will be reported back to the main agent
        3. Do not initiate conversations or take on side tasks
        4. Be concise but informative in your findings

        ## What You Can Do
        - Read and write files in the workspace
        - Execute shell commands
        - Search the web and fetch web pages
        - Complete the task thoroughly

        ## What You Cannot Do
        - Send messages directly to users (no message tool available)
        - Spawn other subagents
        - Access the main agent's conversation history

        ## Workspace
        Your workspace is at: #{@workspace}
        Skills are available at: #{@workspace}/skills/ (read SKILL.md files as needed)

        When you have completed the task, provide a clear summary of your findings or actions.
        PROMPT
      end

      private def build_message(role : String, content : String) : Hash(String, JSON::Any)
        {
          "role"    => JSON::Any.new(role),
          "content" => JSON::Any.new(content),
        }
      end

      private def build_message_with_tools(role : String, content : String, tool_calls : Array(JSON::Any)) : Hash(String, JSON::Any)
        {
          "role"       => JSON::Any.new(role),
          "content"    => JSON::Any.new(content),
          "tool_calls" => JSON::Any.new(tool_calls),
        }
      end

      private def build_tool_result(tool_call_id : String, tool_name : String, result : String) : Hash(String, JSON::Any)
        {
          "role"         => JSON::Any.new("tool"),
          "tool_call_id" => JSON::Any.new(tool_call_id),
          "name"         => JSON::Any.new(tool_name),
          "content"      => JSON::Any.new(result),
        }
      end
    end
  end
end
