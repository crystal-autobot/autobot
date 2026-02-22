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
require "../constants"
require "./context"
require "./tool_executor"

module Autobot
  module Agent
    # Manages background subagent execution.
    #
    # Subagents are lightweight agent instances that run in background fibers
    # to handle specific tasks. They share the same LLM provider but have
    # isolated context and a focused system prompt.
    class SubagentManager
      Log = ::Log.for("subagent")

      MAX_ITERATIONS   = 15
      LABEL_MAX_LENGTH = 30
      TASK_ID_LENGTH   =  8

      enum Status
        Ok
        Error
      end

      @provider : Providers::Provider
      @workspace : Path
      @bus : Bus::MessageBus
      @model : String?
      @brave_api_key : String?
      @exec_timeout : Int32
      @sandbox_config : String
      @running_tasks : Hash(String, Bool) = {} of String => Bool

      def initialize(
        @provider : Providers::Provider,
        @workspace : Path,
        @bus : Bus::MessageBus,
        @model : String? = nil,
        @brave_api_key : String? = nil,
        @exec_timeout : Int32 = 60,
        @sandbox_config : String = "auto",
      )
        @context = Context::Builder.new(@workspace)
      end

      # Spawn a subagent to execute a task in the background.
      def spawn(
        task : String,
        label : String? = nil,
        origin_channel : String = Constants::CHANNEL_CLI,
        origin_chat_id : String = Constants::DEFAULT_CHAT_ID,
      ) : String
        task_id = UUID.random.to_s[0, TASK_ID_LENGTH]
        display_label = label || truncate_label(task)

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
          tools = Tools.create_subagent_registry(
            workspace: @workspace,
            exec_timeout: @exec_timeout,
            sandbox_config: @sandbox_config,
            brave_api_key: @brave_api_key,
          )

          executor = ToolExecutor.new(
            provider: @provider,
            context: @context,
            model: @model || @provider.default_model,
            max_iterations: MAX_ITERATIONS
          )

          messages = build_initial_messages(task)
          result = executor.execute(messages, tools)

          final_result = result.content || "Task completed but no final response was generated."

          Log.info { "Subagent [#{task_id}] completed successfully" }
          announce_result(task_id, label, task, final_result, origin, Status::Ok)
        rescue ex
          error_msg = "Error: #{ex.message}"
          Log.error { "Subagent [#{task_id}] failed: #{ex.message}" }
          announce_result(task_id, label, task, error_msg, origin, Status::Error)
        end
      end

      private def build_initial_messages(task : String) : Array(Hash(String, JSON::Any))
        [
          {"role" => JSON::Any.new(Constants::ROLE_SYSTEM), "content" => JSON::Any.new(build_subagent_prompt(task))},
          {"role" => JSON::Any.new(Constants::ROLE_USER), "content" => JSON::Any.new(task)},
        ]
      end

      private def announce_result(
        task_id : String,
        label : String,
        task : String,
        result : String,
        origin : Hash(String, String),
        status : Status,
      ) : Nil
        status_text = status.ok? ? "completed successfully" : "failed"

        announce_content = <<-CONTENT
        [Subagent '#{label}' #{status_text}]

        Task: #{task}

        Result:
        #{result}

        Summarize this naturally for the user. Keep it brief (1-2 sentences). Do not mention technical details like "subagent" or task IDs.
        CONTENT

        msg = Bus::InboundMessage.new(
          channel: Constants::CHANNEL_SYSTEM,
          sender_id: Constants::SUBAGENT_SENDER_ID,
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

      private def truncate_label(task : String) : String
        task.size > LABEL_MAX_LENGTH ? task[0, LABEL_MAX_LENGTH] + "..." : task
      end
    end
  end
end
