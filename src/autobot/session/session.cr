require "json"
require "../constants"

module Autobot
  module Session
    # A single message in a conversation session.
    struct Message
      include JSON::Serializable

      property role : String
      property content : String
      property timestamp : String
      property tools_used : Array(String)?

      def initialize(@role : String, @content : String, @timestamp : String = Time.utc.to_rfc3339, @tools_used : Array(String)? = nil)
      end
    end

    # Session metadata stored as first line in JSONL file.
    struct Metadata
      include JSON::Serializable

      @[JSON::Field(key: "_type")]
      property type : String = "metadata"
      property created_at : String
      property updated_at : String
      property metadata : Hash(String, JSON::Any) = {} of String => JSON::Any

      def initialize(@created_at : String = Time.utc.to_rfc3339, @updated_at : String = Time.utc.to_rfc3339, @metadata = {} of String => JSON::Any)
      end
    end

    # A conversation session that stores messages in JSONL format.
    class Session
      DEFAULT_MAX_HISTORY = 25

      property key : String
      property messages : Array(Message)
      property created_at : Time
      property updated_at : Time
      property metadata : Hash(String, JSON::Any)

      def initialize(
        @key : String,
        @messages : Array(Message) = [] of Message,
        @created_at : Time = Time.utc,
        @updated_at : Time = Time.utc,
        @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any,
      )
      end

      # Add a message to the session.
      def add_message(role : String, content : String, tools_used : Array(String)? = nil) : Nil
        msg = Message.new(
          role: role,
          content: content,
          timestamp: Time.utc.to_rfc3339,
          tools_used: tools_used
        )
        @messages << msg
        @updated_at = Time.utc
      end

      # Get message history for LLM context (role + content only).
      def get_history(max_messages : Int32 = DEFAULT_MAX_HISTORY) : Array(Hash(String, String))
        recent = if @messages.size > max_messages
                   @messages[-max_messages..]
                 else
                   @messages
                 end

        recent.map { |message| {"role" => message.role, "content" => message.content} }
      end

      # Clear all messages.
      def clear : Nil
        @messages.clear
        @updated_at = Time.utc
      end
    end
  end
end
