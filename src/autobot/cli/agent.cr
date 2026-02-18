module Autobot
  module CLI
    module Agent
      MAX_HISTORY_LINES = 1000

      def self.history_file : Path
        Config::Loader.data_dir / "history" / "cli_history"
      end

      def self.run(
        config_path : String?,
        message : String?,
        session_id : String,
        markdown : Bool,
        show_logs : Bool,
      ) : Nil
        config = Config::Loader.load(config_path)

        # Run the same startup validation as gateway
        SetupHelper.validate_startup(config, config_path)
        SetupHelper.validate_provider(config)

        _provider_config, provider_name = config.match_provider
        Log.info { "Using provider: #{provider_name}, model: #{config.default_model}" }

        bus = Bus::MessageBus.new
        session_manager = Session::Manager.new(config.workspace_path)
        tool_registry, plugin_registry, mcp_clients = SetupHelper.setup_tools(config)

        if message
          run_single(config, bus, tool_registry, session_manager, session_id, message, markdown)
        else
          run_interactive(config, bus, tool_registry, session_manager, session_id, markdown)
        end
      ensure
        mcp_clients.try { |clients| Mcp.stop_all(clients) }
        plugin_registry.try(&.stop_all)
      end

      private def self.run_single(
        config : Config::Config,
        bus : Bus::MessageBus,
        tool_registry : Tools::Registry,
        session_manager : Session::Manager,
        session_id : String,
        message : String,
        markdown : Bool,
      ) : Nil
        session = session_manager.get_or_create(session_id)
        session.add_message("user", message)

        print "Thinking..."

        response = process_message(config, bus, tool_registry, session, message)

        # Clear "Thinking..." line
        print "\r\e[K"

        session.add_message("assistant", response)
        session_manager.save(session)

        print_response(response, markdown)
      end

      private def self.run_interactive(
        config : Config::Config,
        bus : Bus::MessageBus,
        tool_registry : Tools::Registry,
        session_manager : Session::Manager,
        session_id : String,
        markdown : Bool,
      ) : Nil
        puts LOGO.strip
        puts "Interactive mode (type 'exit' or Ctrl+C to quit)\n"

        session = session_manager.get_or_create(session_id)

        history = load_history
        at_exit { save_history(history) }

        Signal::INT.trap do
          puts "\nGoodbye!"
          exit 0
        end

        loop do
          print "\e[1;34mYou:\e[0m "
          input = gets
          break unless input

          command = input.strip
          next if command.empty?

          if EXIT_COMMANDS.includes?(command.downcase)
            puts "\nGoodbye!"
            break
          end

          history << command

          session.add_message("user", command)
          print "Thinking..."

          response = process_message(config, bus, tool_registry, session, command)

          print "\r\e[K"

          session.add_message("assistant", response)
          session_manager.save(session)

          print_response(response, markdown)
        end
      end

      # Process a message through the agent.
      # Simplified single-turn version — the full agent loop will be integrated
      # once the Agent::Loop implementation is complete.
      def self.process_message(
        config : Config::Config,
        bus : Bus::MessageBus,
        tool_registry : Tools::Registry,
        session : Session::Session,
        message : String,
      ) : String
        provider_config, _provider_name = config.match_provider
        return "Error: No provider configured" unless provider_config

        api_key = provider_config.api_key
        api_base = provider_config.api_base?
        model = config.default_model
        agent_defaults = Config::AgentDefaults.new
        defaults = config.agents.try(&.defaults)
        max_tokens = defaults.try(&.max_tokens) || agent_defaults.max_tokens
        temperature = defaults.try(&.temperature) || agent_defaults.temperature
        memory_window = defaults.try(&.memory_window) || agent_defaults.memory_window

        messages = session.get_history(memory_window)
        tools = tool_registry.definitions

        begin
          provider = Providers::HttpProvider.new(
            api_key: api_key,
            api_base: api_base
          )

          response = provider.chat(
            messages: messages.map { |message_item|
              h = {} of String => JSON::Any
              h["role"] = JSON::Any.new(message_item["role"])
              h["content"] = JSON::Any.new(message_item["content"])
              h
            },
            tools: tools.empty? ? nil : tools,
            model: model,
            max_tokens: max_tokens,
            temperature: temperature
          )

          usage = response.usage
          Log.info { "Tokens: #{usage.prompt_tokens} prompt + #{usage.completion_tokens} completion = #{usage.total_tokens} total" }

          if response.has_tool_calls?
            tool_results = response.tool_calls.map do |tool_call|
              result = tool_registry.execute(tool_call.name, tool_call.arguments)
              {tool_call.id, tool_call.name, result}
            end

            parts = [] of String
            if content = response.content
              parts << content
            end
            tool_results.each do |_id, name, result|
              parts << "[Tool: #{name}] #{result}"
            end
            parts.join("\n\n")
          else
            response.content || "No response generated."
          end
        rescue ex
          Log.error { "Agent error: #{ex.message}" }
          "Error: #{ex.message}"
        end
      end

      private def self.print_response(response : String, _markdown : Bool) : Nil
        puts "\n\e[36mautobot\e[0m"
        puts response
        puts
      end

      private def self.load_history : Array(String)
        Dir.mkdir_p(history_file.parent) unless Dir.exists?(history_file.parent)

        if File.exists?(history_file)
          File.read_lines(history_file).last(MAX_HISTORY_LINES)
        else
          [] of String
        end
      end

      private def self.save_history(history : Array(String)) : Nil
        Dir.mkdir_p(history_file.parent) unless Dir.exists?(history_file.parent)
        entries = history.last(MAX_HISTORY_LINES)
        File.write(history_file, entries.join("\n") + "\n")
      end
    end
  end
end
