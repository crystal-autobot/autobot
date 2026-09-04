require "random/secure"

module Autobot
  module Media
    class Inbox
      DIR_MODE  = 0o700
      FILE_MODE = 0o600
      ID_LENGTH =     4

      EXTENSIONS = {
        "audio/ogg"       => "ogg",
        "audio/mpeg"      => "mp3",
        "audio/mp4"       => "m4a",
        "audio/x-m4a"     => "m4a",
        "audio/wav"       => "wav",
        "audio/webm"      => "webm",
        "image/jpeg"      => "jpg",
        "image/png"       => "png",
        "image/webp"      => "webp",
        "application/pdf" => "pdf",
        "text/plain"      => "txt",
      }

      getter dir : Path

      def initialize(@dir : Path)
      end

      def store(bytes : Bytes, mime_type : String?, fallback_extension : String = "bin") : Path
        ensure_dir
        path = @dir / "#{unique_name}.#{Inbox.extension_for(mime_type, fallback_extension)}"
        File.write(path, bytes)
        File.chmod(path, FILE_MODE)
        path
      end

      def store_transcript(text : String, media_path : Path) : Path
        path = media_path.parent / "#{media_path.stem}.txt"
        File.write(path, text)
        File.chmod(path, FILE_MODE)
        path
      end

      def self.extension_for(mime_type : String?, fallback : String) : String
        return fallback unless mime_type
        EXTENSIONS[mime_type.split(';').first.strip.downcase]? || fallback
      end

      private def ensure_dir : Nil
        return if Dir.exists?(@dir)
        Dir.mkdir_p(@dir)
        File.chmod(@dir, DIR_MODE)
      end

      private def unique_name : String
        "#{Time.utc.to_s("%Y%m%d-%H%M%S")}-#{Random::Secure.hex(ID_LENGTH)}"
      end
    end
  end
end
