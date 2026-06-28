require "./plugin"
require "../tools/result"

module Autobot
  module Plugins
    # Custom plugin to convert text to speech using gTTS.
    class TextToSpeechPlugin < Plugin
      def name : String
        "text_to_speech"
      end

      def description : String
        "Convert text to a voice message using gTTS and ffmpeg"
      end

      def version : String
        "0.1.0"
      end

      def setup(context : PluginContext) : Nil
        context.tool_registry.register(TextToSpeechTool.new(context.workspace))
      end
    end

    # Custom tool to perform TTS generation.
    class TextToSpeechTool < Tools::Tool
      @workspace : Path

      def initialize(@workspace : Path)
      end

      def name : String
        "text_to_speech"
      end

      def description : String
        "Converts written text into a spoken voice file with a unique filename. The tool will return the filename of the generated OGG file, which you should pass to the message tool via its file_path parameter."
      end

      def parameters : Tools::ToolSchema
        Tools::ToolSchema.new(
          properties: {
            "text" => Tools::PropertySchema.new(
              type: "string",
              description: "The text message to convert to speech"
            ),
            "lang" => Tools::PropertySchema.new(
              type: "string",
              description: "Language code: 'es' for Spanish, 'en' for English, etc. (default: 'es')",
              default_value: "es"
            ),
          },
          required: ["text"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : Tools::ToolResult
        text = params["text"].as_s
        lang = params["lang"]?.try(&.as_s) || "es"

        unique_id = Random::Secure.hex(8)
        mp3_filename = "temp_voice_#{unique_id}.mp3"
        ogg_filename = "voice_#{unique_id}.ogg"
        mp3_path = (@workspace / mp3_filename).to_s
        ogg_path = (@workspace / ogg_filename).to_s

        # Runtime dependency check
        unless system_cmd_exists?("gtts-cli")
          return Tools::ToolResult.error("gtts-cli is not installed or available in PATH. Install it via 'pip install gtts'.")
        end
        unless system_cmd_exists?("ffmpeg")
          return Tools::ToolResult.error("ffmpeg is not installed or available in PATH.")
        end

        # Clean up older voice files in the workspace (older than 1 minute)
        begin
          Dir.glob((@workspace / "voice_*.ogg").to_s).each do |file|
            if File.info(file).modification_time < 1.minute.ago
              File.delete(file)
            end
          end
          Dir.glob((@workspace / "temp_voice_*.mp3").to_s).each do |file|
            if File.info(file).modification_time < 1.minute.ago
              File.delete(file)
            end
          end
        rescue ex
          Log.warn { "Failed to clean up old voice files: #{ex.message}" }
        end

        begin
          # 1. Run gtts-cli to generate MP3
          gtts_status = Process.run(
            "gtts-cli",
            ["--lang", lang, text, "--output", mp3_path],
            error: Process::Redirect::Close
          )

          unless gtts_status.success?
            return Tools::ToolResult.error("Failed to generate speech using gtts-cli.")
          end

          unless File.exists?(mp3_path)
            return Tools::ToolResult.error("gtts-cli succeeded but #{mp3_filename} was not created.")
          end

          # 2. Run ffmpeg to convert to Opus OGG (native Telegram voice codec)
          ffmpeg_status = Process.run(
            "ffmpeg",
            ["-y", "-i", mp3_path, "-acodec", "libopus", ogg_path],
            error: Process::Redirect::Close
          )

          unless ffmpeg_status.success?
            return Tools::ToolResult.error("Failed to convert audio using ffmpeg.")
          end

          unless File.exists?(ogg_path)
            return Tools::ToolResult.error("ffmpeg completed but #{ogg_filename} was not created.")
          end

          Tools::ToolResult.success("Voice file generated successfully at #{ogg_filename}. Now call the message tool with file_path='#{ogg_filename}' and content='[Voice message]' to deliver it.")
        rescue ex
          Tools::ToolResult.error("Error generating text-to-speech: #{ex.message}")
        ensure
          # Clean up temp file
          File.delete(mp3_path) if File.exists?(mp3_path)
        end
      end

      private def system_cmd_exists?(cmd : String) : Bool
        Process.run("which", [cmd], error: Process::Redirect::Close).success?
      rescue
        false
      end
    end
  end
end
