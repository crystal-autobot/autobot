require "random/secure"

module Autobot
  module Media
    class Inbox
      DIR_MODE  = 0o700
      FILE_MODE = 0o600
      ID_LENGTH =     4

      def initialize(@dir : Path)
      end

      def store(bytes : Bytes, extension : String) : Path
        Dir.mkdir_p(@dir, DIR_MODE)
        path = @dir / "#{unique_name}#{extension}"
        File.write(path, bytes, perm: FILE_MODE)
        path
      end

      def store_transcript(text : String, media_path : Path) : Path
        path = media_path.parent / "#{media_path.stem}.txt"
        File.write(path, text, perm: FILE_MODE)
        path
      end

      private def unique_name : String
        "#{Time.utc.to_s("%Y%m%d-%H%M%S")}-#{Random::Secure.hex(ID_LENGTH)}"
      end
    end
  end
end
