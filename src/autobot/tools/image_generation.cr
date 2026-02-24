require "base64"
require "http/client"
require "json"
require "../bus/events"
require "./result"

module Autobot
  module Tools
    # Tool for generating images from text prompts and sending them to users.
    #
    # Follows the same `send_callback` + `set_context` pattern as MessageTool.
    # When the LLM calls `generate_image(prompt)`, the tool:
    # 1. Calls the provider's image generation API (OpenAI or Gemini)
    # 2. Gets base64 image data back
    # 3. Constructs an OutboundMessage with MediaAttachment
    # 4. Publishes it via the send callback
    class ImageGenerationTool < Tool
      Log = ::Log.for("tools.image_generation")

      IMAGE_GEN_TIMEOUT = 120.seconds

      OPENAI_API_BASE = "https://api.openai.com"
      GEMINI_API_BASE = "https://generativelanguage.googleapis.com"

      DEFAULT_OPENAI_MODEL = "gpt-image-1"
      DEFAULT_GEMINI_MODEL = "gemini-2.0-flash-exp"

      VALID_SIZES = ["256x256", "512x512", "1024x1024", "1024x1536", "1536x1024", "auto"]

      @send_callback : SendCallback?
      @default_channel : String = ""
      @default_chat_id : String = ""

      def initialize(
        @api_key : String,
        @provider_name : String,
        @model : String? = nil,
        @size : String = "1024x1024",
        @api_base : String? = nil,
      )
      end

      def set_context(channel : String, chat_id : String) : Nil
        @default_channel = channel
        @default_chat_id = chat_id
      end

      def send_callback=(callback : SendCallback) : Nil
        @send_callback = callback
      end

      def name : String
        "generate_image"
      end

      def description : String
        "Generate an image from a text description and send it to the user. " \
        "Use this when the user asks you to create, draw, or generate an image."
      end

      def parameters : ToolSchema
        ToolSchema.new(
          properties: {
            "prompt" => PropertySchema.new(
              type: "string",
              description: "Detailed description of the image to generate",
              min_length: 1
            ),
            "size" => PropertySchema.new(
              type: "string",
              description: "Image size",
              enum_values: VALID_SIZES,
              default_value: @size
            ),
          },
          required: ["prompt"]
        )
      end

      def execute(params : Hash(String, JSON::Any)) : ToolResult
        callback = @send_callback
        return ToolResult.error("Image sending not configured") unless callback

        channel = @default_channel
        chat_id = @default_chat_id
        if channel.empty? || chat_id.empty?
          return ToolResult.error("No target channel/chat specified")
        end

        prompt = params["prompt"].as_s
        size = params["size"]?.try(&.as_s) || @size

        Log.info { "Generating image: provider=#{@provider_name}, prompt=#{prompt[0, 80]}" }

        image_data, mime_type = call_provider(prompt, size)

        msg = Bus::OutboundMessage.new(
          channel: channel,
          chat_id: chat_id,
          content: prompt,
          media: [Bus::MediaAttachment.new(
            type: "photo",
            mime_type: mime_type,
            data: image_data,
          )]
        )

        callback.call(msg)
        ToolResult.success("Image generated and sent to #{channel}:#{chat_id}")
      rescue ex
        Log.error { "Image generation failed: #{ex.message}" }
        ToolResult.error("Image generation failed: #{ex.message}")
      end

      private def call_provider(prompt : String, size : String) : {String, String}
        case @provider_name.downcase
        when "openai"
          generate_openai(prompt, size)
        when "gemini"
          generate_gemini(prompt)
        else
          raise "Unsupported image generation provider: #{@provider_name}"
        end
      end

      private def generate_openai(prompt : String, size : String) : {String, String}
        model = @model || DEFAULT_OPENAI_MODEL
        base = @api_base || OPENAI_API_BASE

        body = {
          "model"           => model,
          "prompt"          => prompt,
          "n"               => 1,
          "size"            => size,
          "response_format" => "b64_json",
        }.to_json

        uri = URI.parse(base)
        client = build_client(uri)

        headers = HTTP::Headers{
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type"  => "application/json",
        }

        response = client.post("/v1/images/generations", headers: headers, body: body)
        client.close

        unless response.status_code == 200
          error_msg = parse_error(response.body)
          raise "OpenAI image API error (HTTP #{response.status_code}): #{error_msg}"
        end

        data = JSON.parse(response.body)
        b64 = data["data"][0]["b64_json"].as_s
        {b64, "image/png"}
      end

      private def generate_gemini(prompt : String) : {String, String}
        model = @model || DEFAULT_GEMINI_MODEL

        body = {
          "contents" => [{
            "parts" => [{"text" => "Generate an image: #{prompt}"}],
          }],
          "generationConfig" => {
            "responseModalities" => ["TEXT", "IMAGE"],
          },
        }.to_json

        uri = URI.parse(GEMINI_API_BASE)
        client = build_client(uri)

        path = "/v1beta/models/#{model}:generateContent?key=#{@api_key}"
        headers = HTTP::Headers{"Content-Type" => "application/json"}

        response = client.post(path, headers: headers, body: body)
        client.close

        unless response.status_code == 200
          error_msg = parse_error(response.body)
          raise "Gemini image API error (HTTP #{response.status_code}): #{error_msg}"
        end

        data = JSON.parse(response.body)
        extract_gemini_image(data)
      end

      private def extract_gemini_image(data : JSON::Any) : {String, String}
        candidates = data["candidates"]?.try(&.as_a?)
        if candidates.nil? || candidates.empty?
          raise "No candidates in Gemini response"
        end

        parts = candidates[0]["content"]?
          .try(&.["parts"]?)
          .try(&.as_a?)
        raise "No parts in Gemini response" unless parts

        parts.each do |part|
          if inline_data = part["inlineData"]?
            b64 = inline_data["data"].as_s
            mime = inline_data["mimeType"]?.try(&.as_s) || "image/png"
            return {b64, mime}
          end
        end

        raise "No image data in Gemini response"
      end

      private def build_client(uri : URI) : HTTP::Client
        client = HTTP::Client.new(uri)
        client.read_timeout = IMAGE_GEN_TIMEOUT
        client.connect_timeout = 30.seconds
        client
      end

      private def parse_error(body : String) : String
        data = JSON.parse(body)
        data["error"]?.try(&.["message"]?.try(&.as_s)) || "unknown error"
      rescue
        "unparseable response"
      end
    end
  end
end
