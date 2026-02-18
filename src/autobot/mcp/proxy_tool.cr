require "../tools/base"

module Autobot
  module Mcp
    # Wraps a single MCP server tool as an autobot `Tools::Tool`.
    #
    # The LLM sees proxy tools as native autobot tools. Each tool is named
    # `mcp_{server}_{tool}` (sanitized to `[a-z0-9_]`) to avoid collisions.
    #
    # `to_schema` passes the raw MCP `inputSchema` directly to the LLM,
    # preserving nested JSON Schema that autobot's `ToolSchema` cannot represent.
    class ProxyTool < Tools::Tool
      Log = ::Log.for("mcp.proxy_tool")

      SANITIZE_PATTERN = /[^a-z0-9_]/
      COLLAPSE_PATTERN = /_+/

      getter name : String
      getter description : String
      getter parameters : Tools::ToolSchema

      @raw_input_schema : JSON::Any?

      def initialize(
        @client : Client,
        @remote_name : String,
        @name : String,
        @description : String,
        @parameters : Tools::ToolSchema,
        @raw_input_schema : JSON::Any? = nil,
      )
      end

      def execute(params : Hash(String, JSON::Any)) : Tools::ToolResult
        unless @client.alive?
          return Tools::ToolResult.error("MCP server '#{@client.server_name}' is not running")
        end

        result = @client.call_tool(@remote_name, params)
        Tools::ToolResult.success(result)
      rescue ex
        Log.error { "MCP tool #{@name} failed: #{ex.message}" }
        Tools::ToolResult.error("MCP tool error: #{ex.message}")
      end

      # Override to pass raw MCP inputSchema directly to the LLM,
      # preserving nested JSON Schema that ToolSchema can't represent.
      def to_schema : Hash(String, JSON::Any)
        if raw = @raw_input_schema
          {
            "type"     => JSON::Any.new("function"),
            "function" => JSON::Any.new({
              "name"        => JSON::Any.new(@name),
              "description" => JSON::Any.new(@description),
              "parameters"  => raw,
            }),
          }
        else
          super
        end
      end

      # Builds a `ProxyTool` from an MCP `tools/list` entry.
      #
      # Extracts name, description, and inputSchema from the tool JSON,
      # prefixes the name, and stores the raw schema for `to_schema`.
      def self.from_mcp_tool(client : Client, tool_json : JSON::Any) : ProxyTool
        remote_name = tool_json["name"]?.try(&.as_s?) || "unknown"
        raw_desc = tool_json["description"]?.try(&.as_s?) || ""
        raw_schema = tool_json["inputSchema"]?

        prefixed_name = build_name(client.server_name, remote_name)
        prefixed_desc = "[#{client.server_name}] #{raw_desc}"
        schema = convert_schema(raw_schema)

        ProxyTool.new(
          client: client,
          remote_name: remote_name,
          name: prefixed_name,
          description: prefixed_desc,
          parameters: schema,
          raw_input_schema: raw_schema,
        )
      end

      # Sanitize and prefix: mcp_{server}_{tool}, only [a-z0-9_]
      def self.build_name(server_name : String, tool_name : String) : String
        sanitized_server = sanitize(server_name)
        sanitized_tool = sanitize(tool_name)
        "mcp_#{sanitized_server}_#{sanitized_tool}"
      end

      protected def self.sanitize(value : String) : String
        value.downcase.gsub(SANITIZE_PATTERN, "_").gsub(COLLAPSE_PATTERN, "_").strip('_')
      end

      # Best-effort conversion of MCP `inputSchema` to autobot's `ToolSchema`.
      #
      # Maps known JSON Schema types to `PropertySchema`; falls back to
      # `"string"` for unrecognized types. Used for basic validation only —
      # the raw schema is sent to the LLM via `to_schema`.
      def self.convert_schema(raw : JSON::Any?) : Tools::ToolSchema
        return Tools::ToolSchema.new unless raw

        props = {} of String => Tools::PropertySchema
        required = [] of String

        if properties = raw["properties"]?.try(&.as_h?)
          properties.each do |key, prop|
            props[key] = convert_property(prop)
          end
        end

        if req = raw["required"]?.try(&.as_a?)
          req.each do |item|
            if name = item.as_s?
              required << name
            end
          end
        end

        Tools::ToolSchema.new(properties: props, required: required)
      end

      private def self.convert_property(prop : JSON::Any) : Tools::PropertySchema
        type = prop["type"]?.try(&.as_s?) || "string"
        type = "string" unless Tools::Tool::VALID_SCHEMA_TYPES.includes?(type)
        desc = prop["description"]?.try(&.as_s?) || ""

        enum_values = prop["enum"]?.try(&.as_a?.try(&.compact_map(&.as_s?)))

        items = if type == "array" && (items_raw = prop["items"]?)
                  convert_property(items_raw)
                end

        Tools::PropertySchema.new(
          type: type,
          description: desc,
          enum_values: enum_values,
          items: items,
        )
      end
    end
  end
end
