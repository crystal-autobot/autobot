require "http/client"
require "json"
require "uri"
require "log"

module Autobot::Providers
  # AWS Bedrock provider using the Converse API with optional Guardrails.
  #
  # Unlike HttpProvider, this uses AWS SigV4 authentication and a different
  # request/response format (camelCase, union-key content blocks, nested configs).
  class BedrockProvider < Provider
    Log = ::Log.for(self)

    CONNECT_TIMEOUT = 30.seconds
    READ_TIMEOUT    = 300.seconds
    SERVICE_NAME    = "bedrock"
    CONTENT_TYPE    = "application/json"

    STOP_REASON_MAP = {
      "end_turn"             => "stop",
      "tool_use"             => "tool_calls",
      "max_tokens"           => "length",
      "stop_sequence"        => "stop",
      "guardrail_intervened" => "guardrail_intervened",
      "content_filtered"     => "content_filtered",
    }

    getter model : String
    getter region : String

    @signer : AwsSigv4::Signer
    @client : HTTP::Client?

    def initialize(
      @access_key_id : String,
      @secret_access_key : String,
      @region : String,
      @model : String = "anthropic.claude-3-5-sonnet-20241022-v2:0",
      @session_token : String? = nil,
      @guardrail_id : String? = nil,
      @guardrail_version : String? = nil,
    )
      # Provider base class requires api_key; pass access_key_id for compatibility
      super(@access_key_id)

      @signer = AwsSigv4::Signer.new(
        access_key_id: @access_key_id,
        secret_access_key: @secret_access_key,
        region: @region,
        service: SERVICE_NAME,
        session_token: @session_token,
      )
    end

    def default_model : String
      @model
    end

    def chat(
      messages : Array(Hash(String, JSON::Any)),
      tools : Array(Hash(String, JSON::Any))? = nil,
      model : String? = nil,
      max_tokens : Int32 = DEFAULT_MAX_TOKENS,
      temperature : Float64 = DEFAULT_TEMPERATURE,
    ) : Response
      effective_model = strip_prefix(model || @model)
      body = build_request_body(messages, tools, max_tokens, temperature)
      url = build_endpoint_url(effective_model)

      Log.debug { "POST #{url} model=#{effective_model}" }
      response_body = execute_request(url, body.to_json)
      parse_response(response_body)
    rescue ex
      Log.error { "Bedrock request failed: #{ex.message}" }
      Response.new(content: "Error calling Bedrock: #{ex.message}", finish_reason: "error")
    end

    private def build_request_body(
      messages : Array(Hash(String, JSON::Any)),
      tools : Array(Hash(String, JSON::Any))?,
      max_tokens : Int32,
      temperature : Float64,
    ) : Hash(String, JSON::Any)
      body = {} of String => JSON::Any

      system_blocks = MessageConverter.extract_system(messages)
      body["system"] = JSON::Any.new(system_blocks) unless system_blocks.empty?

      body["messages"] = JSON::Any.new(MessageConverter.convert(messages))
      body["inferenceConfig"] = build_inference_config(max_tokens, temperature)

      if tool_config = ToolConverter.build_tool_config(tools)
        body["toolConfig"] = tool_config
      end

      if guardrail_config = build_guardrail_config
        body["guardrailConfig"] = guardrail_config
      end

      body
    end

    private def build_inference_config(max_tokens : Int32, temperature : Float64) : JSON::Any
      JSON::Any.new({
        "maxTokens"   => JSON::Any.new(max_tokens.to_i64),
        "temperature" => JSON::Any.new(temperature),
      } of String => JSON::Any)
    end

    private def build_guardrail_config : JSON::Any?
      id = @guardrail_id
      version = @guardrail_version
      return nil unless id && version

      JSON::Any.new({
        "guardrailIdentifier" => JSON::Any.new(id),
        "guardrailVersion"    => JSON::Any.new(version),
        "trace"               => JSON::Any.new("enabled"),
      } of String => JSON::Any)
    end

    private def build_endpoint_url(model_id : String) : String
      encoded_model = URI.encode_path_segment(model_id)
      "https://bedrock-runtime.#{@region}.amazonaws.com/model/#{encoded_model}/converse"
    end

    private def execute_request(url_str : String, body : String) : String
      url = URI.parse(url_str)
      headers = HTTP::Headers{"Content-Type" => CONTENT_TYPE}

      @signer.sign("POST", url, headers, body)

      client = get_or_create_client(url)
      response = client.post(url.request_target, headers: headers, body: body)
      Log.debug { "Response #{response.status_code} (#{response.body.size} bytes)" }

      response.body
    end

    private def get_or_create_client(url : URI) : HTTP::Client
      if client = @client
        return client
      end

      host = url.host
      raise "Invalid URL: missing host" unless host

      client = HTTP::Client.new(host, port: url.port, tls: true)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      @client = client
      client
    end

    private def parse_response(body : String) : Response
      json = JSON.parse(body)

      if error = extract_error(json, body)
        return error
      end

      output_message = json.dig("output", "message")
      content_blocks = output_message["content"]?.try(&.as_a?) || [] of JSON::Any
      text_parts, tool_calls = parse_content_blocks(content_blocks)
      usage = parse_bedrock_usage(json["usage"]?)
      finish_reason = map_stop_reason(json["stopReason"]?.try(&.as_s?))

      log_guardrail_trace(json["trace"]?)

      Response.new(
        content: text_parts.empty? ? nil : text_parts.join("\n"),
        tool_calls: tool_calls,
        finish_reason: finish_reason,
        usage: usage,
      )
    end

    private def extract_error(json : JSON::Any, body : String) : Response?
      if msg = json["message"]?.try(&.as_s?)
        error_type = json["__type"]?.try(&.as_s?) || "UnknownError"
        Log.error { "Bedrock error: #{error_type}: #{msg}" }
        return Response.new(content: "Bedrock error: #{msg}", finish_reason: "error")
      end
      nil
    end

    private def parse_content_blocks(blocks : Array(JSON::Any)) : {Array(String), Array(ToolCall)}
      text_parts = [] of String
      tool_calls = [] of ToolCall

      blocks.each do |block|
        if text = block["text"]?.try(&.as_s?)
          text_parts << text
        elsif tool_use = block["toolUse"]?
          if tc = parse_tool_use(tool_use)
            tool_calls << tc
          end
        end
      end

      {text_parts, tool_calls}
    end

    private def parse_tool_use(tool_use : JSON::Any) : ToolCall?
      id = tool_use["toolUseId"]?.try(&.as_s?) || ""
      name = tool_use["name"]?.try(&.as_s?) || ""
      input = tool_use["input"]?.try(&.as_h?) || {} of String => JSON::Any
      args = input.transform_values(&.as(JSON::Any))
      ToolCall.new(id: id, name: name, arguments: args)
    end

    private def parse_bedrock_usage(node : JSON::Any?) : TokenUsage
      return TokenUsage.new unless node
      input = node["inputTokens"]?.try(&.as_i?) || 0
      output = node["outputTokens"]?.try(&.as_i?) || 0
      TokenUsage.new(
        prompt_tokens: input,
        completion_tokens: output,
        total_tokens: node["totalTokens"]?.try(&.as_i?) || (input + output),
      )
    end

    private def map_stop_reason(reason : String?) : String
      return "stop" unless reason
      STOP_REASON_MAP[reason]? || reason
    end

    private def log_guardrail_trace(trace : JSON::Any?) : Nil
      return unless trace
      if guardrail_trace = trace["guardrail"]?
        Log.info { "Guardrail trace: #{guardrail_trace.to_json}" }
      end
    end

    private def strip_prefix(model : String) : String
      model.starts_with?("bedrock/") ? model[8..] : model
    end
  end
end
