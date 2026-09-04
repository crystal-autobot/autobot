require "html"
require "../bus/events"

module Autobot
  module Agent
    module Attachments
      MAX_INLINE_TRANSCRIPT = 4000

      def self.render(attachment : Bus::MediaAttachment, workspace_root : Path) : String
        "<attachment#{attributes(attachment, workspace_root)}>\n#{body(attachment, workspace_root)}\n</attachment>"
      end

      private def self.attributes(attachment : Bus::MediaAttachment, root : Path) : String
        {
          "type"     => attachment.type,
          "origin"   => attachment.origin,
          "name"     => attachment.name,
          "path"     => attachment.file_path.try { |path| display_path(path, root) },
          "duration" => attachment.duration_seconds.try { |seconds| "#{seconds}s" },
        }.compact.join { |(key, value)| %( #{key}="#{escape(value)}") }
      end

      private def self.body(attachment : Bus::MediaAttachment, root : Path) : String
        if transcript = attachment.transcript
          inline_transcript(transcript, attachment.transcript_path, root)
        elsif attachment.sender_voice_note?
          "Spoken by the sender; the transcription is in the message text."
        elsif attachment.data
          "Image attached below."
        else
          "No transcript."
        end
      end

      private def self.inline_transcript(transcript : String, transcript_path : String?, root : Path) : String
        text = transcript.gsub("</attachment", "[/attachment")
        return text if text.size <= MAX_INLINE_TRANSCRIPT

        pointer = transcript_path ? " Full transcript: #{display_path(transcript_path, root)}" : ""
        "#{text[0, MAX_INLINE_TRANSCRIPT]}\n[transcript truncated.#{pointer}]"
      end

      private def self.display_path(path : String, root : Path) : String
        expanded = Path[path].expand(home: true)
        expanded.to_s.starts_with?(root.to_s) ? expanded.relative_to(root).to_s : path
      end

      private def self.escape(value : String) : String
        HTML.escape(value.gsub('\n', ' '))
      end
    end
  end
end
