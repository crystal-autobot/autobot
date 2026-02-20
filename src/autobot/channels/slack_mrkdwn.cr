module Autobot::Channels
  # Converts standard Markdown to Slack mrkdwn format.
  #
  # Slack mrkdwn differences from standard Markdown:
  # - Bold: *text* (single asterisk, not double)
  # - Italic: _text_ (same)
  # - Strikethrough: ~text~ (single tilde, not double)
  # - Links: <url|text> (not [text](url))
  # - Code: `code` and ```code``` (same, but no language hints)
  # - Headers: not supported natively, converted to bold
  # - Blockquotes: > text (same)
  module MarkdownToSlackMrkdwn
    SLACK_MAX_LENGTH = 40_000

    CODE_BLOCK_PREFIX  = "\x00CB"
    INLINE_CODE_PREFIX = "\x00IC"
    SUFFIX             = "\x00"

    CODE_BLOCK_REGEX  = /```(\w*)\n?([\s\S]*?)```/
    INLINE_CODE_REGEX = /`([^`]+)`/

    HEADER_REGEX          = Regex.new(%q(^#{1,6}\s+(.+)$), Regex::Options::MULTILINE)
    HR_REGEX              = /^[-*_]{3,}\s*$/m
    LINK_REGEX            = /\[([^\]]+)\]\(([^)]+)\)/
    BOLD_STAR_REGEX       = /\*\*(.+?)\*\*/
    BOLD_UNDERSCORE_REGEX = /__(.+?)__/
    STRIKETHROUGH_REGEX   = /~~(.+?)~~/
    BULLET_LIST_REGEX     = /^[-*]\s+/m

    def self.convert(text : String) : String
      return "" if text.empty?

      code_blocks = [] of String
      inline_codes = [] of String

      result = text
      result = extract_code_blocks(result, code_blocks)
      result = extract_inline_code(result, inline_codes)

      result = convert_headers(result)
      result = result.gsub(HR_REGEX, "")
      result = convert_links(result)
      result = convert_bold(result)
      result = convert_strikethrough(result)
      result = convert_bullets(result)

      result = restore_placeholders(result, inline_codes, code_blocks)
      result.strip
    end

    def self.split_message(text : String) : Array(String)
      return [text] if text.size <= SLACK_MAX_LENGTH
      split_by_paragraphs(text)
    end

    private def self.extract_code_blocks(text : String, store : Array(String)) : String
      text.gsub(CODE_BLOCK_REGEX) do |_, match|
        store << "```\n#{match[2]}```"
        "#{CODE_BLOCK_PREFIX}#{store.size - 1}#{SUFFIX}"
      end
    end

    private def self.extract_inline_code(text : String, store : Array(String)) : String
      text.gsub(INLINE_CODE_REGEX) do |_, match|
        store << "`#{match[1]}`"
        "#{INLINE_CODE_PREFIX}#{store.size - 1}#{SUFFIX}"
      end
    end

    private def self.convert_headers(text : String) : String
      text.gsub(HEADER_REGEX, "*\\1*")
    end

    private def self.convert_links(text : String) : String
      text.gsub(LINK_REGEX) { |_, match| "<#{match[2]}|#{match[1]}>" }
    end

    private def self.convert_bold(text : String) : String
      result = text.gsub(BOLD_STAR_REGEX, "*\\1*")
      result.gsub(BOLD_UNDERSCORE_REGEX, "*\\1*")
    end

    private def self.convert_strikethrough(text : String) : String
      text.gsub(STRIKETHROUGH_REGEX, "~\\1~")
    end

    private def self.convert_bullets(text : String) : String
      text.gsub(BULLET_LIST_REGEX, "\u{2022} ")
    end

    private def self.restore_placeholders(text : String, inline_codes : Array(String), code_blocks : Array(String)) : String
      result = text
      inline_codes.each_with_index do |code, i|
        result = result.gsub("#{INLINE_CODE_PREFIX}#{i}#{SUFFIX}", code)
      end
      code_blocks.each_with_index do |code, i|
        result = result.gsub("#{CODE_BLOCK_PREFIX}#{i}#{SUFFIX}", code)
      end
      result
    end

    private def self.split_by_paragraphs(text : String) : Array(String)
      chunks = [] of String
      current = ""

      text.split("\n\n").each do |para|
        candidate = current.empty? ? para : "#{current}\n\n#{para}"
        if candidate.size <= SLACK_MAX_LENGTH
          current = candidate
        else
          chunks << current unless current.empty?
          current = para.size <= SLACK_MAX_LENGTH ? para : para[0, SLACK_MAX_LENGTH]
        end
      end

      chunks << current unless current.empty?
      chunks
    end
  end
end
