require "html"
require "../bus/events"

module Autobot
  module Agent
    module Attachments
      TAG          = "attachment"
      CLOSING_TAG  = "</#{TAG}"
      NEUTRALIZED  = "[/#{TAG}"
      IMAGE_NOTE   = "Image attached below."
      SPOKEN_NOTE  = "Spoken by the sender; the transcription is in the message text."
      MISSING_NOTE = "No transcript."

      def self.render(attachment : Bus::MediaAttachment, workspace : Path) : String
        "<#{TAG}#{attributes(attachment, workspace)}>\n#{body(attachment)}\n</#{TAG}>"
      end

      private def self.attributes(attachment : Bus::MediaAttachment, workspace : Path) : String
        pairs = {
          "type"     => attachment.type,
          "origin"   => attachment.origin,
          "name"     => attachment.name,
          "path"     => attachment.file_path.try { |path| display_path(path, workspace) },
          "duration" => attachment.duration_seconds.try { |seconds| "#{seconds}s" },
        }
        pairs.compact_map { |key, value| %( #{key}="#{escape(value)}") if value }.join
      end

      private def self.body(attachment : Bus::MediaAttachment) : String
        if transcript = attachment.transcript
          transcript.gsub(CLOSING_TAG, NEUTRALIZED)
        elsif attachment.sender_voice_note?
          SPOKEN_NOTE
        elsif attachment.data
          IMAGE_NOTE
        else
          MISSING_NOTE
        end
      end

      private def self.display_path(path : String, workspace : Path) : String
        expanded = Path[path].expand(home: true)
        root = workspace.expand(home: true)
        expanded.to_s.starts_with?(root.to_s) ? expanded.relative_to(root).to_s : path
      end

      private def self.escape(value : String) : String
        HTML.escape(value.gsub('\n', ' '))
      end
    end
  end
end
