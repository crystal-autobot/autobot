require "../plugin"
require "../../tools/result"

module Autobot
  module Plugins
    module Builtin
      # Weather plugin that provides a tool for fetching weather data.
      #
      # Uses wttr.in (no API key required) for weather lookups.
      class WeatherPlugin < Plugin
        def name : String
          "weather"
        end

        def description : String
          "Get current weather and forecasts via wttr.in (no API key required)"
        end

        def version : String
          "0.1.0"
        end

        def setup(context : PluginContext) : Nil
          context.tool_registry.register(WeatherTool.new)
        end
      end

      # Tool that fetches weather data from wttr.in.
      class WeatherTool < Tools::Tool
        BASE_URL        = "wttr.in"
        BRIEF_TIMEOUT_S = "10"
        FULL_TIMEOUT_S  = "15"
        BRIEF_FORMAT    = "format=%l:+%c+%t+%h+%w"
        NO_DATA_MESSAGE = "No weather data available for this location."

        def name : String
          "get_weather"
        end

        def description : String
          "Get current weather for a location using wttr.in. Returns temperature, conditions, humidity, and wind."
        end

        def parameters : Tools::ToolSchema
          Tools::ToolSchema.new(
            properties: {
              "location" => Tools::PropertySchema.new(
                type: "string",
                description: "City name, airport code, or coordinates (e.g. 'London', 'JFK', '48.8566,2.3522')"
              ),
              "format" => Tools::PropertySchema.new(
                type: "string",
                description: "Output format: 'brief' for one-line summary, 'full' for 3-day forecast",
                enum_values: ["brief", "full"],
                default_value: "brief"
              ),
            },
            required: ["location"]
          )
        end

        def execute(params : Hash(String, JSON::Any)) : Tools::ToolResult
          location = URI.encode_path(params["location"].as_s)
          format = params["format"]?.try(&.as_s) || "brief"

          case format
          when "full"
            fetch("#{BASE_URL}/#{location}?T", FULL_TIMEOUT_S)
          else
            fetch("#{BASE_URL}/#{location}?#{BRIEF_FORMAT}", BRIEF_TIMEOUT_S)
          end
        end

        private def fetch(url : String, timeout : String) : Tools::ToolResult
          output = IO::Memory.new
          status = Process.run(
            "curl",
            ["-s", "-m", timeout, url],
            output: output,
            error: Process::Redirect::Close
          )

          unless status.success?
            return Tools::ToolResult.error("Failed to fetch weather data. Check if the location is valid.")
          end

          result = output.to_s.strip
          content = result.empty? ? NO_DATA_MESSAGE : result
          Tools::ToolResult.success(content)
        end
      end
    end
  end
end
