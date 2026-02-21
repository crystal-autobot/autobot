require "./base"
require "./telegram"
require "./slack"
require "./whatsapp"
require "../config/schema"
require "../bus/queue"
require "../transcriber"

module Autobot::Channels
  # Manages chat channels and coordinates message routing.
  #
  # Responsibilities:
  # - Initialize enabled channels from config
  # - Start/stop all channels
  # - Route outbound messages to the appropriate channel
  class Manager
    Log = ::Log.for("channels.manager")

    WHISPER_PROVIDERS = ["groq", "openai"]

    getter channels : Hash(String, Channel) = {} of String => Channel
    getter transcriber : Transcriber? = nil

    def initialize(@config : Config::Config, @bus : Bus::MessageBus, @session_manager : Session::Manager? = nil)
      @transcriber = detect_transcriber
      init_channels
    end

    # Start all enabled channels and the outbound dispatcher.
    def start : Nil
      if @channels.empty?
        Log.warn { "No channels enabled" }
        return
      end

      # Start outbound message dispatcher
      spawn(name: "outbound-dispatcher") { dispatch_outbound }

      # Start each channel in its own fiber
      @channels.each do |name, channel|
        Log.info { "Starting #{name} channel..." }
        spawn(name: "channel-#{name}") do
          begin
            channel.start
          rescue ex
            Log.error { "Failed to start channel #{name}: #{ex.message}" }
          end
        end
      end
    end

    # Stop all channels gracefully.
    def stop : Nil
      Log.info { "Stopping all channels..." }
      @channels.each do |name, channel|
        begin
          channel.stop
          Log.info { "Stopped #{name} channel" }
        rescue ex
          Log.error { "Error stopping #{name}: #{ex.message}" }
        end
      end
    end

    # Get a channel by name.
    def channel(name : String) : Channel?
      @channels[name]?
    end

    # Get status of all channels.
    def status : Hash(String, NamedTuple(enabled: Bool, running: Bool))
      @channels.transform_values do |channel_instance|
        {enabled: true, running: channel_instance.running?}
      end
    end

    # List enabled channel names.
    def enabled_channels : Array(String)
      @channels.keys
    end

    # Create a streaming callback for the given channel and chat_id.
    # Delegates to the channel's own implementation (OCP-compliant).
    def create_stream_callback(channel : String, chat_id : String) : Providers::StreamCallback?
      @channels[channel]?.try(&.create_stream_callback(chat_id))
    end

    private def detect_transcriber : Transcriber?
      providers = @config.providers
      return nil unless providers

      WHISPER_PROVIDERS.each do |name|
        provider = case name
                   when "groq"   then providers.groq
                   when "openai" then providers.openai
                   else               nil
                   end
        if provider && !provider.api_key.empty?
          Log.info { "Voice transcription enabled (#{name})" }
          return Transcriber.new(api_key: provider.api_key, provider: name)
        end
      end

      Log.info { "Voice transcription unavailable (no openai/groq provider)" }
      nil
    end

    private def init_channels : Nil
      return unless channels_config = @config.channels

      if telegram_config = channels_config.telegram
        if telegram_config.enabled?
          custom_cmds = telegram_config.custom_commands || Config::CustomCommandsConfig.from_yaml("{}")
          @channels["telegram"] = TelegramChannel.new(
            bus: @bus,
            token: telegram_config.token,
            allow_from: telegram_config.allow_from,
            proxy: telegram_config.proxy?,
            custom_commands: custom_cmds,
            session_manager: @session_manager,
            transcriber: @transcriber,
            streaming_enabled: telegram_config.streaming?,
          )
          streaming_label = telegram_config.streaming? ? " (streaming)" : ""
          Log.info { "Telegram channel enabled#{streaming_label}" }
        end
      end

      if slack_config = channels_config.slack
        if slack_config.enabled?
          dm_cfg = slack_config.dm || Config::SlackDMConfig.from_yaml("{}")
          @channels["slack"] = SlackChannel.new(
            bus: @bus,
            bot_token: slack_config.bot_token,
            app_token: slack_config.app_token,
            allow_from: slack_config.allow_from,
            group_policy: slack_config.group_policy,
            group_allow_from: slack_config.group_allow_from,
            dm_config: dm_cfg,
          )
          Log.info { "Slack channel enabled" }
        end
      end

      if whatsapp_config = channels_config.whatsapp
        if whatsapp_config.enabled?
          @channels["whatsapp"] = WhatsAppChannel.new(
            bus: @bus,
            bridge_url: whatsapp_config.bridge_url,
            allow_from: whatsapp_config.allow_from,
          )
          Log.info { "WhatsApp channel enabled" }
        end
      end
    end

    # Dispatch outbound messages from the bus to the appropriate channel.
    private def dispatch_outbound : Nil
      Log.info { "Outbound dispatcher started" }
      @bus.consume_outbound do |message|
        channel = @channels[message.channel]?
        if channel
          begin
            channel.send_message(message)
          rescue ex
            Log.error { "Error sending to #{message.channel}: #{ex.message}" }
          end
        else
          Log.warn { "No channel found for: #{message.channel}" }
        end
      end
    end
  end
end
