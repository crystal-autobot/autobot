require "base64"
require "json"
require "../bus/events"
require "../media/inbox"
require "../transcriber"

module Autobot::Channels
  # A voice note the sender recorded is their spoken words; files and forwards are content.
  class TelegramMedia
    alias Fetcher = Proc(String, Bytes?)

    FORWARD_KEYS = %w[forward_origin forward_from forward_from_chat forward_sender_name forward_date]

    PHOTO_MIME    = "image/jpeg"
    VOICE_MIME    = "audio/ogg"
    AUDIO_MIME    = "audio/mpeg"
    VOICE_MISSING = "[voice message]"
    PHOTO_LABEL   = "[photo]"

    def initialize(@fetch : Fetcher, @transcriber : Transcriber? = nil, @inbox : Media::Inbox? = nil)
    end

    def extract(msg : JSON::Any, typed_text : Bool) : {Array(String), Array(Bus::MediaAttachment)}
      origin = forwarded?(msg) ? Bus::MediaAttachment::ORIGIN_FORWARDED : Bus::MediaAttachment::ORIGIN_SENDER
      parts = [] of String
      attachments = [] of Bus::MediaAttachment

      extract_photo(msg, origin).try { |attachment| attachments << attachment }
      extract_voice(msg, origin, typed_text, parts).try { |attachment| attachments << attachment }
      extract_audio(msg, origin).try { |attachment| attachments << attachment }
      extract_document(msg, origin).try { |attachment| attachments << attachment }

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
      build(Bus::MediaAttachment::TYPE_PHOTO, photo, origin, PHOTO_MIME, bytes,
        data: bytes.try { |data| Base64.strict_encode(data) })
    end

    private def extract_voice(msg : JSON::Any, origin : String, typed_text : Bool, parts : Array(String)) : Bus::MediaAttachment?
      voice = msg["voice"]?
      return nil unless voice

      bytes = fetch(voice)
      mime = mime_of(voice, VOICE_MIME)
      transcript = transcribe(bytes, mime)
      spoken = origin == Bus::MediaAttachment::ORIGIN_SENDER && !typed_text

      parts << spoken_text(transcript) if spoken
      build(Bus::MediaAttachment::TYPE_VOICE, voice, origin, mime, bytes,
        transcript: spoken ? nil : transcript)
    end

    private def extract_audio(msg : JSON::Any, origin : String) : Bus::MediaAttachment?
      audio = msg["audio"]?
      return nil unless audio

      bytes = fetch(audio)
      mime = mime_of(audio, AUDIO_MIME)
      build(Bus::MediaAttachment::TYPE_AUDIO, audio, origin, mime, bytes,
        transcript: transcribe(bytes, mime),
        name: string_of(audio, "title") || string_of(audio, "file_name"))
    end

    private def extract_document(msg : JSON::Any, origin : String) : Bus::MediaAttachment?
      document = msg["document"]?
      return nil unless document

      build(Bus::MediaAttachment::TYPE_DOCUMENT, document, origin, string_of(document, "mime_type"), fetch(document),
        name: string_of(document, "file_name"))
    end

    private def build(type : String, node : JSON::Any, origin : String, mime : String?, bytes : Bytes?,
                      data : String? = nil, transcript : String? = nil, name : String? = nil) : Bus::MediaAttachment
      path = bytes.try { |content| @inbox.try(&.store(content, mime, type)) }
      transcript_path = store_transcript(transcript, path)

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

    private def store_transcript(transcript : String?, media_path : Path?) : Path?
      return nil unless transcript && media_path
      @inbox.try(&.store_transcript(transcript, media_path))
    end

    private def placeholders(attachments : Array(Bus::MediaAttachment)) : Array(String)
      attachments.reject(&.spoken_instruction?).map { |attachment| placeholder(attachment) }
    end

    private def placeholder(attachment : Bus::MediaAttachment) : String
      case attachment.type
      when Bus::MediaAttachment::TYPE_PHOTO then PHOTO_LABEL
      when Bus::MediaAttachment::TYPE_VOICE then VOICE_MISSING
      when Bus::MediaAttachment::TYPE_AUDIO then "[audio: #{attachment.name || "audio"}]"
      else                                       "[document: #{attachment.name || "unknown"}]"
      end
    end

    private def spoken_text(transcript : String?) : String
      transcript ? "[voice transcription]: #{transcript}" : VOICE_MISSING
    end

    private def transcribe(bytes : Bytes?, mime : String) : String?
      transcriber = @transcriber
      return nil unless transcriber && bytes
      transcriber.transcribe(bytes, "audio.#{extension_for(mime)}")
    end

    private def extension_for(mime : String) : String
      Media::Inbox.extension_for(mime, "ogg")
    end

    private def fetch(node : JSON::Any) : Bytes?
      @fetch.call(node["file_id"].as_s)
    end

    private def mime_of(node : JSON::Any, fallback : String) : String
      string_of(node, "mime_type") || fallback
    end

    private def string_of(node : JSON::Any, key : String) : String?
      node[key]?.try(&.as_s?)
    end
  end
end
