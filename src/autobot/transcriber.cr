require "http/client"
require "json"

module Autobot
  # Speech-to-text transcription via Whisper API (OpenAI or Groq).
  #
  # Usage:
  #   transcriber = Transcriber.new(api_key: "sk-...", provider: "openai")
  #   text = transcriber.transcribe(audio_bytes, "voice.ogg")
  class Transcriber
    Log = ::Log.for("transcriber")

    PROVIDERS = {
      "openai" => {
        url:   "https://api.openai.com/v1/audio/transcriptions",
        model: "whisper-1",
      },
      "groq" => {
        url:   "https://api.groq.com/openai/v1/audio/transcriptions",
        model: "whisper-large-v3-turbo",
      },
    }

    BOUNDARY = "----AutobotWhisperBoundary"

    getter provider : String

    def initialize(@api_key : String, @provider : String = "openai")
    end

    # Transcribe audio data to text.
    # Returns the transcribed text, or nil on failure.
    def transcribe(audio_data : Bytes, filename : String = "voice.ogg") : String?
      config = PROVIDERS[@provider]?
      unless config
        Log.warn { "Unknown transcription provider: #{@provider}" }
        return nil
      end

      body = build_multipart_body(audio_data, filename, config[:model])
      headers = HTTP::Headers{
        "Authorization" => "Bearer #{@api_key}",
        "Content-Type"  => "multipart/form-data; boundary=#{BOUNDARY}",
      }

      response = HTTP::Client.post(config[:url], headers: headers, body: body)
      parse_response(response)
    rescue ex
      Log.warn { "Transcription failed: #{ex.message}" }
      nil
    end

    private def build_multipart_body(audio_data : Bytes, filename : String, model : String) : String
      io = IO::Memory.new

      # File field
      io << "--" << BOUNDARY << "\r\n"
      io << "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n"
      io << "Content-Type: application/octet-stream\r\n\r\n"
      io.write(audio_data)
      io << "\r\n"

      # Model field
      io << "--" << BOUNDARY << "\r\n"
      io << "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
      io << model << "\r\n"

      # Closing boundary
      io << "--" << BOUNDARY << "--\r\n"

      io.to_s
    end

    private def parse_response(response : HTTP::Client::Response) : String?
      unless response.status_code == 200
        Log.warn { "Transcription API error (HTTP #{response.status_code}): #{extract_error(response.body)}" }
        return nil
      end

      data = JSON.parse(response.body)
      text = data["text"]?.try(&.as_s)

      if text && !text.empty?
        Log.debug { "Transcription successful (#{text.size} chars)" }
        text
      else
        Log.warn { "Transcription returned empty text" }
        nil
      end
    rescue ex
      Log.warn { "Failed to parse transcription response: #{ex.message}" }
      nil
    end

    private def extract_error(body : String) : String
      JSON.parse(body)["error"]?.try(&.["message"]?.try(&.as_s)) || "unknown error"
    rescue
      "unparseable response"
    end
  end
end
