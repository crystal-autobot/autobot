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
require "./tool_executor"

module Autobot::Agent
  # The agent loop is the core processing engine
  #
  # It:
  # 1. Receives messages from the bus
  # 2. Builds context with history, memory, skills
  # 3. Calls the LLM via ToolExecutor
  # 4. Sends responses back
  class Loop
    Log = ::Log.for("agent.loop")

    SHORT_MESSAGE_PREVIEW_LENGTH =  80
    LONG_MESSAGE_PREVIEW_LENGTH  = 120

    HEARTBEAT_INTERVAL = 1.second

    # Tools excluded from background turns (cron jobs, subagent work).
    BACKGROUND_EXCLUDED_TOOLS = ["spawn"]

    GENERIC_ERROR_MESSAGE = "Sorry, I encountered an unexpected error. Please try again."
    FALLBACK_RESPONSE     = "I've completed processing but have no response to give."

    @running : Bool = false
    @cron_service : Cron::Service?
    @memory_manager : MemoryManager
    @model : String

    # Cached tool references (avoids stringly-typed lookups per message)
    @spawn_tool : Tools::SpawnTool?
    @cron_tool : Tools::CronTool?
    @message_tool : Tools::MessageTool?

    def initialize(
      @bus : Bus::MessageBus,
      @provider : Providers::Provider,
      @workspace : Path,
      @tools : Tools::Registry,
      @sessions : Session::Manager,
      model : String? = nil,
      @max_iterations : Int32 = 20,
      @memory_window : Int32 = 50,
      @cron_service : Cron::Service? = nil,
      brave_api_key : String? = nil,
      exec_timeout : Int32 = 60,
      sandbox_config : String = "auto",
    )
      @model = model || @provider.default_model
      sandboxed = sandbox_config.downcase != "none"
      @context = Context::Builder.new(@workspace, sandboxed)

      @executor = ToolExecutor.new(
        provider: @provider,
        context: @context,
        model: @model,
        max_iterations: @max_iterations
      )

      @memory_manager = MemoryManager.new(
        workspace: @workspace,
        provider: @provider,
        model: @model,
        memory_window: @memory_window,
        sessions: @sessions
      )

      register_optional_tools(brave_api_key, exec_timeout, sandbox_config)
      cache_tool_references
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

          @bus.publish_outbound(Bus::OutboundMessage.new(
            channel: msg.channel,
            chat_id: msg.chat_id,
            content: GENERIC_ERROR_MESSAGE
          ))
        end
      end

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

    # Process a single inbound message
    private def process_message(msg : Bus::InboundMessage, session_key : String? = nil) : Bus::OutboundMessage?
      return process_system_message(msg) if msg.channel == Constants::CHANNEL_SYSTEM

      log_incoming_message(msg)

      session = @sessions.get_or_create(session_key || msg.session_key)

      if @memory_manager.enabled?
        @memory_manager.consolidate_if_needed(session)
      else
        @memory_manager.trim_if_disabled(session)
      end

      update_tool_contexts(msg.channel, msg.chat_id)
      messages = @context.build_messages(
        history: session.get_history,
        current_message: msg.content,
        media: msg.media?,
        channel: msg.channel,
        chat_id: msg.chat_id,
        tool_names: @tools.tool_names
      )

      result = @executor.execute(messages, @tools, session_key: session.key)
      final_content = result.content || FALLBACK_RESPONSE

      save_to_session(session, msg.content, final_content, result.tools_used)
      build_response(msg.channel, msg.chat_id, final_content, msg.metadata)
    end

    # Route system messages to the appropriate handler.
    private def process_system_message(msg : Bus::InboundMessage) : Bus::OutboundMessage?
      Log.debug { "Processing system message from #{msg.sender_id}" }

      if msg.sender_id.starts_with?(Constants::CRON_SENDER_PREFIX)
        process_cron_message(msg)
      else
        process_subagent_message(msg)
      end
    end

    # Handle a cron-triggered background turn.
    # Uses minimal context (no history), stops after the message tool fires.
    # Returns nil because cron turns must deliver via the message tool explicitly.
    private def process_cron_message(msg : Bus::InboundMessage) : Nil
      origin_channel, origin_chat_id = parse_origin(msg.chat_id)
      session = @sessions.get_or_create("#{origin_channel}:#{origin_chat_id}")
      update_tool_contexts(origin_channel, origin_chat_id)

      messages = @context.build_messages(
        history: [] of Hash(String, String),
        current_message: build_cron_prompt(msg),
        channel: origin_channel,
        chat_id: origin_chat_id,
        background: true
      )

      result = @executor.execute(
        messages, @tools,
        session_key: session.key,
        exclude_tools: BACKGROUND_EXCLUDED_TOOLS,
        stop_after_tool: "message"
      )

      Log.info { "Cron turn done: job=#{msg.sender_id.lchop(Constants::CRON_SENDER_PREFIX)}, tools=#{result.tools_used}" }
      nil
    end

    # Handle a subagent result announcement.
    # Runs with full session history, saves the exchange, and returns a response.
    private def process_subagent_message(msg : Bus::InboundMessage) : Bus::OutboundMessage
      origin_channel, origin_chat_id = parse_origin(msg.chat_id)
      session = @sessions.get_or_create("#{origin_channel}:#{origin_chat_id}")
      update_tool_contexts(origin_channel, origin_chat_id)

      messages = @context.build_messages(
        history: session.get_history,
        current_message: msg.content,
        channel: origin_channel,
        chat_id: origin_chat_id,
        tool_names: @tools.tool_names
      )

      result = @executor.execute(messages, @tools, session_key: session.key)
      final_content = result.content || "Background task completed."

      session.add_message(Constants::ROLE_USER, msg.content)
      session.add_message(Constants::ROLE_ASSISTANT, final_content)
      @sessions.save(session)

      Bus::OutboundMessage.new(
        channel: origin_channel,
        chat_id: origin_chat_id,
        content: final_content
      )
    end

    # Parse origin channel/chat_id from system message chat_id (format: "channel:chat_id")
    private def parse_origin(chat_id : String) : {String, String}
      if chat_id.includes?(":")
        parts = chat_id.split(":", 2)
        {parts[0], parts[1]}
      else
        {Constants::CHANNEL_CLI, chat_id}
      end
    end

    # Build prompt for cron-triggered agent turns.
    private def build_cron_prompt(msg : Bus::InboundMessage) : String
      job_id = msg.sender_id.lchop(Constants::CRON_SENDER_PREFIX)
      Log.info { "Cron turn: job=#{job_id}" }

      <<-PROMPT
      This is a scheduled cron execution (job: #{job_id}).
      Rules:
      - Use the `message` tool to deliver results to the user
      - If there is nothing to report, do NOT send a message
      - Do NOT create new cron jobs
      - Do NOT remove this job unless the task explicitly defines a stop condition that has been met

      Task: #{msg.content}
      PROMPT
    end

    private def register_optional_tools(brave_api_key : String?, exec_timeout : Int32, sandbox_config : String) : Nil
      subagents = SubagentManager.new(
        provider: @provider,
        workspace: @workspace,
        bus: @bus,
        model: @model,
        brave_api_key: brave_api_key,
        exec_timeout: exec_timeout,
        sandbox_config: sandbox_config
      )
      @tools.register(Tools::SpawnTool.new(subagents))

      if cron = @cron_service
        @tools.register(Tools::CronTool.new(cron))
      end
    end

    private def cache_tool_references : Nil
      @spawn_tool = @tools.get("spawn").as?(Tools::SpawnTool)
      @cron_tool = @tools.get("cron").as?(Tools::CronTool)
      @message_tool = @tools.get("message").as?(Tools::MessageTool)

      if message_tool = @message_tool
        message_tool.send_callback = ->(msg : Bus::OutboundMessage) { @bus.publish_outbound(msg) }
      end
    end

    # Update spawn, cron, and message tool contexts for current session.
    private def update_tool_contexts(channel : String, chat_id : String) : Nil
      @spawn_tool.try(&.set_context(channel, chat_id))
      @cron_tool.try(&.set_context(channel, chat_id))
      @message_tool.try(&.set_context(channel, chat_id))
    end

    private def save_to_session(session : Session::Session, user_content : String, assistant_content : String, tools_used : Array(String)) : Nil
      session.add_message(Constants::ROLE_USER, user_content, nil)
      session.add_message(Constants::ROLE_ASSISTANT, assistant_content, tools_used.empty? ? nil : tools_used)
      @sessions.save(session)
    end

    private def build_response(channel : String, chat_id : String, content : String, metadata : Hash(String, String) = {} of String => String) : Bus::OutboundMessage
      preview = truncate(content, LONG_MESSAGE_PREVIEW_LENGTH)
      Log.info { "Response: #{preview}" }

      Bus::OutboundMessage.new(
        channel: channel,
        chat_id: chat_id,
        content: content,
        metadata: metadata,
      )
    end

    private def log_incoming_message(msg : Bus::InboundMessage) : Nil
      preview = truncate(msg.content, SHORT_MESSAGE_PREVIEW_LENGTH)
      Log.info { "Processing message from #{msg.channel}:#{msg.sender_id}: #{preview}" }
    end

    private def truncate(text : String, max_length : Int32) : String
      text.size > max_length ? text[0, max_length] + "..." : text
    end
  end
end
