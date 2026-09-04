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

    TYPE_PHOTO    = "photo"
    TYPE_VOICE    = "voice"
    TYPE_AUDIO    = "audio"
    TYPE_DOCUMENT = "document"

    ORIGIN_SENDER    = "sender"
    ORIGIN_FORWARDED = "forwarded"

    property type : String
    property url : String?
    property file_path : String?
    property mime_type : String?
    property size_bytes : Int64?
    property origin : String = ORIGIN_SENDER
    property transcript : String?
    property transcript_path : String?
    property duration_seconds : Int32?
    property name : String?

    @[JSON::Field(ignore: true)]
    property data : String?

    def initialize(
      @type : String,
      @url : String? = nil,
      @file_path : String? = nil,
      @mime_type : String? = nil,
      @size_bytes : Int64? = nil,
      @data : String? = nil,
      @origin : String = ORIGIN_SENDER,
      @transcript : String? = nil,
      @transcript_path : String? = nil,
      @duration_seconds : Int32? = nil,
      @name : String? = nil,
    )
    end

    def sender_voice_note? : Bool
      type == TYPE_VOICE && origin == ORIGIN_SENDER
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
