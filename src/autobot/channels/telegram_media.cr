require "base64"
require "json"
require "../bus/events"
require "../media/inbox"
require "../media/types"
require "../transcriber"

module Autobot::Channels
  # A voice note the sender recorded is their spoken words; files and forwards are content.
  class TelegramMedia
    alias Fetcher = Proc(String, Bytes?)

    FORWARD_KEYS  = %w[forward_origin forward_from forward_from_chat forward_sender_name forward_date]
    VOICE_MISSING = "[voice message]"

    def initialize(@fetch : Fetcher, @transcriber : Transcriber? = nil, @inbox : Media::Inbox? = nil)
    end

    def extract(msg : JSON::Any, typed_text : Bool) : {Array(String), Array(Bus::MediaAttachment)}
      forwarded = forwarded?(msg)
      origin = forwarded ? Bus::MediaAttachment::ORIGIN_FORWARDED : Bus::MediaAttachment::ORIGIN_SENDER
      spoken = !typed_text && !forwarded

      voice, spoken_text = extract_voice(msg, origin, spoken)
      attachments = [extract_photo(msg, origin), voice, extract_audio(msg, origin), extract_document(msg, origin)].compact

      parts = [] of String
      parts << spoken_text if spoken_text
      parts.concat(placeholders(attachments)) unless typed_text
      {parts, attachments}
    end

    def forwarded?(msg : JSON::Any) : Bool
      FORWARD_KEYS.any? { |key| msg[key]? }
    end

    private def extract_photo(msg : JSON::Any, origin : String) : Bus::MediaAttachment?
      photo = msg["photo"]?.try(&.as_a?).try(&.last?)
      return nil unless photo

      bytes = fetch(photo)
      build(Bus::MediaAttachment::TYPE_PHOTO, photo, origin, {".jpg", "image/jpeg"}, bytes,
        data: bytes.try { |data| Base64.strict_encode(data) })
    end

    private def extract_voice(msg : JSON::Any, origin : String, spoken : Bool) : {Bus::MediaAttachment?, String?}
      voice = msg["voice"]?
      return {nil, nil} unless voice

      bytes = fetch(voice)
      format = format_of(voice, Bus::MediaAttachment::TYPE_VOICE, "audio/ogg")
      transcript = transcribe(bytes, format[0])
      attachment = build(Bus::MediaAttachment::TYPE_VOICE, voice, origin, format, bytes,
        transcript: spoken ? nil : transcript)
      {attachment, spoken ? spoken_text(transcript) : nil}
    end

    private def extract_audio(msg : JSON::Any, origin : String) : Bus::MediaAttachment?
      audio = msg["audio"]?
      return nil unless audio

      bytes = fetch(audio)
      format = format_of(audio, Bus::MediaAttachment::TYPE_AUDIO, "audio/mpeg")
      build(Bus::MediaAttachment::TYPE_AUDIO, audio, origin, format, bytes,
        transcript: transcribe(bytes, format[0]),
        name: string_of(audio, "title") || string_of(audio, "file_name"))
    end

    private def extract_document(msg : JSON::Any, origin : String) : Bus::MediaAttachment?
      document = msg["document"]?
      return nil unless document

      build(Bus::MediaAttachment::TYPE_DOCUMENT, document, origin,
        format_of(document, Bus::MediaAttachment::TYPE_DOCUMENT, Media::Types::DEFAULT[1]), fetch(document),
        name: string_of(document, "file_name"))
    end

    # The platform file name is the most reliable source of the format; Telegram
    # often omits mime_type, and Whisper rejects a mislabelled extension.
    private def format_of(node : JSON::Any, type : String, default_mime : String) : {String, String}
      name_extension = File.extname(string_of(node, "file_name") || "").downcase
      mime = string_of(node, "mime_type")
      return {name_extension, mime || Media::Types.for_extension(name_extension)[1]} unless name_extension.empty?

      mime ||= default_mime
      {Media::Types.extension_for(mime, ".#{type}"), mime}
    end

    private def build(type : String, node : JSON::Any, origin : String, format : {String, String}, bytes : Bytes?,
                      data : String? = nil, transcript : String? = nil, name : String? = nil) : Bus::MediaAttachment
      extension, mime = format
      path = bytes.try { |content| @inbox.try(&.store(content, extension)) }
      transcript_path = transcript && path ? @inbox.try(&.store_transcript(transcript, path)) : nil

      Bus::MediaAttachment.new(
        type: type,
        url: node["file_id"].as_s,
        file_path: path.try(&.to_s),
        mime_type: mime,
        size_bytes: node["file_size"]?.try(&.as_i64?),
        data: data,
        origin: origin,
        transcript: transcript,
        transcript_path: transcript_path.try(&.to_s),
        duration_seconds: node["duration"]?.try(&.as_i?),
        name: name,
      )
    end

    private def placeholders(attachments : Array(Bus::MediaAttachment)) : Array(String)
      attachments.reject(&.sender_voice_note?).map { |attachment| placeholder(attachment) }
    end

    private def placeholder(attachment : Bus::MediaAttachment) : String
      case attachment.type
      when Bus::MediaAttachment::TYPE_PHOTO then "[photo]"
      when Bus::MediaAttachment::TYPE_VOICE then VOICE_MISSING
      when Bus::MediaAttachment::TYPE_AUDIO then "[audio: #{attachment.name || "audio"}]"
      else                                       "[document: #{attachment.name || "unknown"}]"
      end
    end

    private def spoken_text(transcript : String?) : String
      transcript ? "[voice transcription]: #{transcript}" : VOICE_MISSING
    end

    private def transcribe(bytes : Bytes?, extension : String) : String?
      transcriber = @transcriber
      return nil unless transcriber && bytes
      transcriber.transcribe(bytes, "audio#{extension}")
    end

    private def fetch(node : JSON::Any) : Bytes?
      @fetch.call(node["file_id"].as_s)
    end

    private def string_of(node : JSON::Any, key : String) : String?
      node[key]?.try(&.as_s?)
    end
  end
end
