require "json"

module Autobot::Bus
  # Inbound message from a chat channel
  struct InboundMessage
    include JSON::Serializable

    property channel : String
    property sender_id : String
    property chat_id : String
    property content : String
    property timestamp : Time
    property? media : Array(MediaAttachment)?
    property metadata : Hash(String, String)

    def initialize(
      @channel : String,
      @sender_id : String,
      @chat_id : String,
      @content : String,
      @timestamp : Time = Time.utc,
      @media : Array(MediaAttachment)? = nil,
      @metadata : Hash(String, String) = {} of String => String,
    )
    end

    # Session key for persistence
    def session_key : String
      "#{channel}:#{chat_id}"
    end
  end

  # Media attachment (photo, voice, document, etc.)
  struct MediaAttachment
    include JSON::Serializable

    property type : String # "photo", "voice", "document", "video"
    property url : String?
    property file_path : String?
    property mime_type : String?
    property size_bytes : Int64?

    @[JSON::Field(ignore: true)]
    property data : String?

    def initialize(
      @type : String,
      @url : String? = nil,
      @file_path : String? = nil,
      @mime_type : String? = nil,
      @size_bytes : Int64? = nil,
      @data : String? = nil,
    )
    end
  end

  # Outbound message to send via a channel
  struct OutboundMessage
    include JSON::Serializable

    property channel : String
    property chat_id : String
    property content : String
    property? reply_to : String?
    property? media : Array(MediaAttachment)?
    property metadata : Hash(String, String)

    def initialize(
      @channel : String,
      @chat_id : String,
      @content : String,
      @reply_to : String? = nil,
      @media : Array(MediaAttachment)? = nil,
      @metadata : Hash(String, String) = {} of String => String,
    )
    end
  end
end
