require "./result"

module Autobot
  module Tools
    # Abstract base class for agent tools.
    #
    # Tools are capabilities the agent can use to interact with the
    # environment — reading files, executing commands, searching the web, etc.
    #
    # Subclasses must implement `name`, `description`, `parameters`, and `execute`.
    abstract class Tool
      VALID_SCHEMA_TYPES = {"string", "integer", "number", "boolean", "array", "object"}

      abstract def name : String
      abstract def description : String
      abstract def parameters : ToolSchema
      abstract def execute(params : Hash(String, JSON::Any)) : ToolResult

      # Convert tool to OpenAI function-calling schema format.
      def to_schema : Hash(String, JSON::Any)
        {
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new({
            "name"        => JSON::Any.new(name),
            "description" => JSON::Any.new(description),
            "parameters"  => parameters.to_json_any,
          }),
        }
      end

      # Validate parameters against the tool's JSON Schema.
      # Returns an array of error messages (empty if valid).
      def validate_params(params : Hash(String, JSON::Any)) : Array(String)
        parameters.validate(params)
      end
    end

    # Describes a tool's parameter schema (JSON Schema subset).
    class ToolSchema
      getter properties : Hash(String, PropertySchema)
      getter required : Array(String)

      def initialize(
        @properties = {} of String => PropertySchema,
        @required = [] of String,
      )
      end

      def validate(params : Hash(String, JSON::Any)) : Array(String)
        errors = [] of String

        @required.each do |key|
          errors << "missing required parameter '#{key}'" unless params.has_key?(key)
        end

        params.each do |key, value|
          if prop = @properties[key]?
            errors.concat(prop.validate(value, key))
          end
        end

        errors
      end

      def to_json_any : JSON::Any
        props = {} of String => JSON::Any
        @properties.each do |key, prop|
          props[key] = prop.to_json_any
        end

        obj = {
          "type"       => JSON::Any.new("object"),
          "properties" => JSON::Any.new(props),
          "required"   => JSON::Any.new(@required.map { |required_key| JSON::Any.new(required_key) }),
        }

        JSON::Any.new(obj)
      end
    end

    # Describes a single property in a tool's parameter schema.
    class PropertySchema
      getter type : String
      getter description : String
      getter enum_values : Array(String)?
      getter minimum : Int64?
      getter maximum : Int64?
      getter min_length : Int32?
      getter max_length : Int32?
      getter default_value : String?
      getter items : PropertySchema?

      def initialize(
        @type = "string",
        @description = "",
        @enum_values = nil,
        @minimum = nil,
        @maximum = nil,
        @min_length = nil,
        @max_length = nil,
        @default_value = nil,
        @items = nil,
      )
      end

      def validate(value : JSON::Any, path : String) : Array(String)
        case @type
        when "string"
          validate_string(value, path)
        when "integer"
          validate_integer(value, path)
        when "number"
          validate_number(value, path)
        when "boolean"
          validate_boolean(value, path)
        when "array"
          validate_array(value, path)
        when "object"
          validate_object(value, path)
        else
          [] of String
        end
      end

      private def validate_string(value : JSON::Any, path : String) : Array(String)
        errors = [] of String
        unless text = value.as_s?
          errors << "'#{path}' should be string"
          return errors
        end

        if min_len = @min_length
          errors << "'#{path}' must be at least #{min_len} chars" if text.size < min_len
        end
        if max_len = @max_length
          errors << "'#{path}' must be at most #{max_len} chars" if text.size > max_len
        end
        if enum_values = @enum_values
          errors << "'#{path}' must be one of #{enum_values}" unless enum_values.includes?(text)
        end
        errors
      end

      private def validate_integer(value : JSON::Any, path : String) : Array(String)
        errors = [] of String
        unless number = value.as_i64?
          errors << "'#{path}' should be integer"
          return errors
        end

        append_numeric_bounds_errors(errors, path, number.to_f)
        errors
      end

      private def validate_number(value : JSON::Any, path : String) : Array(String)
        errors = [] of String
        number = value.as_f? || value.as_i64?.try(&.to_f)
        unless number
          errors << "'#{path}' should be number"
          return errors
        end

        append_numeric_bounds_errors(errors, path, number)
        errors
      end

      private def append_numeric_bounds_errors(errors : Array(String), path : String, number : Float64) : Nil
        if min = @minimum
          errors << "'#{path}' must be >= #{min}" if number < min
        end
        if max = @maximum
          errors << "'#{path}' must be <= #{max}" if number > max
        end
      end

      private def validate_boolean(value : JSON::Any, path : String) : Array(String)
        return [] of String if value.as_bool? != nil
        ["'#{path}' should be boolean"]
      end

      private def validate_array(value : JSON::Any, path : String) : Array(String)
        errors = [] of String
        unless arr = value.as_a?
          errors << "'#{path}' should be array"
          return errors
        end

        if item_schema = @items
          arr.each_with_index do |item, index|
            errors.concat(item_schema.validate(item, "#{path}[#{index}]"))
          end
        end
        errors
      end

      private def validate_object(value : JSON::Any, path : String) : Array(String)
        return [] of String if value.as_h?
        ["'#{path}' should be object"]
      end

      def to_json_any : JSON::Any
        obj = {} of String => JSON::Any
        obj["type"] = JSON::Any.new(@type)
        obj["description"] = JSON::Any.new(@description) unless @description.empty?

        if ev = @enum_values
          obj["enum"] = JSON::Any.new(ev.map { |v| JSON::Any.new(v) })
        end
        if min = @minimum
          obj["minimum"] = JSON::Any.new(min)
        end
        if max = @maximum
          obj["maximum"] = JSON::Any.new(max)
        end
        if ml = @min_length
          obj["minLength"] = JSON::Any.new(ml.to_i64)
        end
        if ml = @max_length
          obj["maxLength"] = JSON::Any.new(ml.to_i64)
        end
        if dv = @default_value
          obj["default"] = JSON::Any.new(dv)
        end
        if item_schema = @items
          obj["items"] = item_schema.to_json_any
        end

        JSON::Any.new(obj)
      end
    end
  end
end
