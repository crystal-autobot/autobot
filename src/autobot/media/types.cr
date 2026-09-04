module Autobot
  module Media
    module Types
      DEFAULT = {"document", "application/octet-stream"}

      BY_EXTENSION = {
        ".jpg"  => {"photo", "image/jpeg"},
        ".jpeg" => {"photo", "image/jpeg"},
        ".png"  => {"photo", "image/png"},
        ".webp" => {"photo", "image/webp"},
        ".bmp"  => {"photo", "image/bmp"},
        ".gif"  => {"animation", "image/gif"},
        ".mp4"  => {"video", "video/mp4"},
        ".pdf"  => {"document", "application/pdf"},
        ".txt"  => {"document", "text/plain"},
        ".ogg"  => {"voice", "audio/ogg"},
        ".mp3"  => {"audio", "audio/mpeg"},
        ".m4a"  => {"audio", "audio/mp4"},
        ".wav"  => {"audio", "audio/wav"},
        ".webm" => {"audio", "audio/webm"},
      }

      EXTENSION_BY_MIME = BY_EXTENSION
        .each_with_object({} of String => String) { |(ext, (_, mime)), map| map[mime] ||= ext }
        .merge({"audio/x-m4a" => ".m4a"})

      def self.for_extension(extension : String) : {String, String}
        BY_EXTENSION[extension.downcase]? || DEFAULT
      end

      def self.extension_for(mime_type : String?, fallback : String) : String
        return fallback unless mime_type
        EXTENSION_BY_MIME[mime_type.split(';').first.strip.downcase]? || fallback
      end
    end
  end
end
