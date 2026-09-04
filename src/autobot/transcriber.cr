require "http/client"
require "json"
require "./config/schema"

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

    DEFAULT_PROVIDER = "openai"
    PROVIDER_ORDER   = ["groq", "openai"]

    record Source, provider : String, api_key : String, own_key : Bool

    getter provider : String

    def initialize(@api_key : String, @provider : String = DEFAULT_PROVIDER)
    end

    def self.from_config(config : Config::Config) : Transcriber?
      source(config).try { |found| new(api_key: found.api_key, provider: found.provider) }
    end

    def self.source(config : Config::Config) : Source?
      transcription = config.transcription
      return nil unless transcription.enabled?

      pinned = transcription.provider
      return nil if pinned && !PROVIDERS.has_key?(pinned)
      if own_key = transcription.own_key
        return Source.new(pinned || DEFAULT_PROVIDER, own_key, own_key: true)
      end

      candidates = pinned ? [pinned] : PROVIDER_ORDER
      candidates.each do |name|
        key = provider_key(config, name)
        return Source.new(name, key, own_key: false) if key
      end
      nil
    end

    private def self.provider_key(config : Config::Config, name : String) : String?
      providers = config.providers
      return nil unless providers

      provider = case name
                 when "groq"   then providers.groq
                 when "openai" then providers.openai
                 end
      provider.try(&.api_key.presence)
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
