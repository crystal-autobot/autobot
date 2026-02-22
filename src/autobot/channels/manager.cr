require "./base"
require "./telegram"
require "./slack"
require "./whatsapp"
require "../config/schema"
require "../bus/queue"
require "../cron/service"
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

    def initialize(
      @config : Config::Config,
      @bus : Bus::MessageBus,
      @session_manager : Session::Manager? = nil,
      @cron_service : Cron::Service? = nil,
    )
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

      init_telegram(channels_config.telegram)
      init_slack(channels_config.slack)
      init_whatsapp(channels_config.whatsapp)
      init_zulip(channels_config.zulip)
    end

    private def init_telegram(config)
      return unless config && config.enabled?

      custom_cmds = config.custom_commands || Config::CustomCommandsConfig.from_yaml("{}")
      @channels["telegram"] = TelegramChannel.new(
        bus: @bus,
        token: config.token,
        allow_from: config.allow_from,
        proxy: config.proxy?,
        custom_commands: custom_cmds,
        session_manager: @session_manager,
        transcriber: @transcriber,
        cron_service: @cron_service,
      )
      Log.info { "Telegram channel enabled" }
    end

    private def init_slack(config)
      return unless config && config.enabled?

      dm_cfg = config.dm || Config::SlackDMConfig.from_yaml("{}")
      @channels["slack"] = SlackChannel.new(
        bus: @bus,
        bot_token: config.bot_token,
        app_token: config.app_token,
        allow_from: config.allow_from,
        group_policy: config.group_policy,
        group_allow_from: config.group_allow_from,
        dm_config: dm_cfg,
      )
      Log.info { "Slack channel enabled" }
    end

    private def init_whatsapp(config)
      return unless config && config.enabled?

      @channels["whatsapp"] = WhatsAppChannel.new(
        bus: @bus,
        bridge_url: config.bridge_url,
        allow_from: config.allow_from,
      )
      Log.info { "WhatsApp channel enabled" }
    end

    private def init_zulip(config)
      return unless config && config.enabled?

      @channels["zulip"] = ZulipChannel.new(
        bus: @bus,
        site: config.site,
        email: config.email,
        api_key: config.api_key,
        allow_from: config.allow_from,
      )
      Log.info { "Zulip channel enabled" }
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
