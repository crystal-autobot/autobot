require "json"
require "../bus/queue"
require "../bus/events"
require "../providers/provider"
require "../tools/registry"
require "../tools/spawn"
require "../tools/cron_tool"
require "../tools/message"
require "../session/manager"
require "../cron/service"
require "../constants"
require "./context"
require "./memory"
require "./memory_manager"
require "./skills"
require "./subagent"

module Autobot::Agent
  # The agent loop is the core processing engine
  #
  # It:
  # 1. Receives messages from the bus
  # 2. Builds context with history, memory, skills
  # 3. Calls the LLM
  # 4. Executes tool calls
  # 5. Sends responses back
  class Loop
    Log = ::Log.for("agent.loop")

    # Message preview lengths for logging
    SHORT_MESSAGE_PREVIEW_LENGTH =  80
    LONG_MESSAGE_PREVIEW_LENGTH  = 120

    # Loop control
    HEARTBEAT_INTERVAL = 1.second

    @running : Bool = false
    @subagents : SubagentManager?
    @cron_service : Cron::Service?
    @memory_manager : MemoryManager
    @sandbox_config : String

    def initialize(
      @bus : Bus::MessageBus,
      @provider : Providers::Provider,
      @workspace : Path,
      @tools : Tools::Registry,
      @sessions : Session::Manager,
      @model : String? = nil,
      @max_iterations : Int32 = 20,
      @memory_window : Int32 = 50,
      @cron_service : Cron::Service? = nil,
      brave_api_key : String? = nil,
      exec_timeout : Int32 = 60,
      @sandbox_config : String = "auto",
    )
      @model = @model || @provider.default_model
      sandboxed = @sandbox_config.downcase != "none"
      @context = Context::Builder.new(@workspace, sandboxed)

      # Setup memory manager
      active_model_str = @model || @provider.default_model
      @memory_manager = MemoryManager.new(
        workspace: @workspace,
        provider: @provider,
        model: active_model_str,
        memory_window: @memory_window,
        sessions: @sessions
      )

      # Setup subagent manager
      @subagents = SubagentManager.new(
        provider: @provider,
        workspace: @workspace,
        bus: @bus,
        model: @model,
        brave_api_key: brave_api_key,
        exec_timeout: exec_timeout,
        sandbox_config: @sandbox_config
      )

      # Register spawn tool
      if subagents = @subagents
        @tools.register(Tools::SpawnTool.new(subagents))
      end

      # Register cron tool
      if cron = @cron_service
        @tools.register(Tools::CronTool.new(cron))
      end
    end

    # Run the agent loop, processing messages from the bus
    def run : Nil
      @running = true
      Log.info { "Agent loop started" }

      @bus.consume_inbound do |msg|
        next unless @running

        begin
          response = process_message(msg)
          @bus.publish_outbound(response) if response
        rescue ex : Exception
          Log.error { "Error processing message: #{ex.message}" }
          Log.error { ex.backtrace.join("\n") }

          # Send error response
          @bus.publish_outbound(Bus::OutboundMessage.new(
            channel: msg.channel,
            chat_id: msg.chat_id,
            content: "Sorry, I encountered an error: #{ex.message}"
          ))
        end
      end

      # Block until stopped
      while @running
        sleep(HEARTBEAT_INTERVAL)
      end

      Log.info { "Agent loop stopped" }
    end

    # Stop the agent loop
    def stop : Nil
      @running = false
      Log.info { "Agent loop stopping..." }
    end

    # Process a single inbound message
    private def process_message(msg : Bus::InboundMessage, session_key : String? = nil) : Bus::OutboundMessage?
      # Handle system messages (subagent announcements)
      return process_system_message(msg) if msg.channel == Constants::CHANNEL_SYSTEM

      log_incoming_message(msg)

      session = @sessions.get_or_create(session_key || msg.session_key)

      if @memory_manager.enabled?
        @memory_manager.consolidate_if_needed(session)
      else
        @memory_manager.trim_if_disabled(session)
      end

      update_tool_contexts(msg.channel, msg.chat_id)
      update_tool_contexts(msg.channel, msg.chat_id)
      messages = @context.build_messages(
        history: session.get_history,
        current_message: msg.content,
        media: msg.media?,
        channel: msg.channel,
        chat_id: msg.chat_id
      )

      # Execute agent loop and get response
      final_content, tools_used = execute_agent_loop(messages, session.key)

      # Save to session
      save_to_session(session, msg.content, final_content, tools_used)

      # Build and return response
      build_response(msg.channel, msg.chat_id, final_content)
    end

    # Process a system message (e.g., subagent announcement).
    # Routes response back to the original channel.
    private def process_system_message(msg : Bus::InboundMessage) : Bus::OutboundMessage?
      Log.info { "Processing system message from #{msg.sender_id}" }

      # Parse origin from chat_id (format: "channel:chat_id")
      origin_channel, origin_chat_id = if msg.chat_id.includes?(":")
                                         parts = msg.chat_id.split(":", 2)
                                         {parts[0], parts[1]}
                                       else
                                         {Constants::CHANNEL_CLI, msg.chat_id}
                                       end

      session = @sessions.get_or_create("#{origin_channel}:#{origin_chat_id}")
      update_tool_contexts(origin_channel, origin_chat_id)

      messages = @context.build_messages(
        history: session.get_history,
        current_message: msg.content,
        channel: origin_channel,
        chat_id: origin_chat_id
      )

      final_content = run_tool_loop(messages, session.key)
      final_content ||= "Background task completed."

      session.add_message(Constants::ROLE_USER, "[System: #{msg.sender_id}] #{msg.content}")
      session.add_message(Constants::ROLE_ASSISTANT, final_content)
      @sessions.save(session)

      Bus::OutboundMessage.new(
        channel: origin_channel,
        chat_id: origin_chat_id,
        content: final_content
      )
    end

    # Run the tool execution loop and return the final content.
    private def run_tool_loop(messages : Array(Hash(String, JSON::Any)), session_key : String) : String?
      final_content : String? = nil

      @max_iterations.times do
        response = @provider.chat(
          messages: messages,
          tools: @tools.definitions,
          model: active_model
        )

        if response.has_tool_calls?
          messages = @context.add_assistant_message(
            messages,
            response.content || "",
            response.tool_calls,
            reasoning_content: response.reasoning_content
          )

          response.tool_calls.each do |tool_call|
            Log.info { "Tool call: #{tool_call.name}" }
            result = @tools.execute(tool_call.name, tool_call.arguments, session_key)
            messages = @context.add_tool_result(messages, tool_call.id, tool_call.name, result)
          end
        else
          final_content = response.content
          break
        end
      end

      final_content
    end

    private def active_model : String
      @model || @provider.default_model
    end

    # Update spawn, cron, and message tool contexts for current session.
    private def update_tool_contexts(channel : String, chat_id : String) : Nil
      if spawn_tool = @tools.get("spawn").as?(Tools::SpawnTool)
        spawn_tool.set_context(channel, chat_id)
      end
      if cron_tool = @tools.get("cron").as?(Tools::CronTool)
        cron_tool.set_context(channel, chat_id)
      end
      if message_tool = @tools.get("message").as?(Tools::MessageTool)
        message_tool.set_context(channel, chat_id)
      end
    end

    # Log incoming message with preview
    private def log_incoming_message(msg : Bus::InboundMessage) : Nil
      preview = msg.content.size > SHORT_MESSAGE_PREVIEW_LENGTH ? msg.content[0..SHORT_MESSAGE_PREVIEW_LENGTH] + "..." : msg.content
      Log.info { "Processing message from #{msg.channel}:#{msg.sender_id}: #{preview}" }
    end

    # Execute the agent loop with tool calls
    private def execute_agent_loop(messages : Array(Hash(String, JSON::Any)), session_key : String) : {String, Array(String)}
      final_content : String? = nil
      tools_used = [] of String

      @max_iterations.times do
        response = call_llm(messages)

        if response.has_tool_calls?
          messages = process_tool_calls(messages, response, tools_used, session_key)
        else
          final_content = response.content
          break
        end
      end

      final_content ||= "I've completed processing but have no response to give."
      {final_content, tools_used}
    end

    # Call LLM and log token usage
    private def call_llm(messages : Array(Hash(String, JSON::Any))) : Providers::Response
      response = @provider.chat(
        messages: messages,
        tools: @tools.definitions,
        model: active_model
      )

      usage = response.usage
      unless usage.zero?
        Log.info { "Tokens: prompt=#{usage.prompt_tokens} completion=#{usage.completion_tokens} total=#{usage.total_tokens}" }
      end

      response
    end

    # Process tool calls and update messages
    private def process_tool_calls(
      messages : Array(Hash(String, JSON::Any)),
      response : Providers::Response,
      tools_used : Array(String),
      session_key : String,
    ) : Array(Hash(String, JSON::Any))
      # Add assistant message with tool calls
      messages = @context.add_assistant_message(
        messages,
        response.content,
        response.tool_calls
      )

      # Execute tools with session-specific rate limiting
      response.tool_calls.each do |tool_call|
        tools_used << tool_call.name
        Log.info { "Tool call: #{tool_call.name}" }

        result = @tools.execute(tool_call.name, tool_call.arguments, session_key)

        messages = @context.add_tool_result(
          messages,
          tool_call.id,
          tool_call.name,
          result
        )
      end

      messages
    end

    # Save messages to session
    private def save_to_session(session : Session::Session, user_content : String, assistant_content : String, tools_used : Array(String)) : Nil
      session.add_message(Constants::ROLE_USER, user_content, nil)
      session.add_message(Constants::ROLE_ASSISTANT, assistant_content, tools_used.empty? ? nil : tools_used)
      @sessions.save(session)
    end

    # Build outbound message with logging
    private def build_response(channel : String, chat_id : String, content : String) : Bus::OutboundMessage
      preview = content.size > LONG_MESSAGE_PREVIEW_LENGTH ? content[0..LONG_MESSAGE_PREVIEW_LENGTH] + "..." : content
      Log.info { "Response: #{preview}" }

      Bus::OutboundMessage.new(
        channel: channel,
        chat_id: chat_id,
        content: content
      )
    end

    # Process a message directly (for CLI or cron usage).
    def process_direct(
      content : String,
      session_key : String = Constants::DEFAULT_SESSION_KEY,
      channel : String = Constants::CHANNEL_CLI,
      chat_id : String = Constants::DEFAULT_CHAT_ID,
    ) : String
      msg = Bus::InboundMessage.new(
        channel: channel,
        sender_id: "user",
        chat_id: chat_id,
        content: content
      )

      response = process_message(msg, session_key: session_key)
      response.try(&.content) || ""
    end
  end
end
