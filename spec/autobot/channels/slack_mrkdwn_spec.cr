require "../../spec_helper"

describe Autobot::Channels::MarkdownToSlackMrkdwn do
  describe ".convert" do
    it "returns empty string for empty input" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("").should eq("")
    end

    it "passes plain text through" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("Hello world").should eq("Hello world")
    end

    it "converts **bold** to *bold*" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("**bold text**").should eq("*bold text*")
    end

    it "converts __bold__ to *bold*" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("__bold text__").should eq("*bold text*")
    end

    it "preserves _italic_ as _italic_" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("_italic text_").should eq("_italic text_")
    end

    it "converts ~~strikethrough~~ to ~strikethrough~" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("~~deleted~~").should eq("~deleted~")
    end

    it "converts [text](url) to <url|text>" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("[click](https://example.com)").should eq("<https://example.com|click>")
    end

    it "converts headers to bold" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("# Title").should eq("*Title*")
    end

    it "converts multi-level headers to bold" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("### Subtitle").should eq("*Subtitle*")
    end

    it "strips horizontal rules" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("above\n---\nbelow").should eq("above\n\nbelow")
    end

    it "strips *** horizontal rules" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("above\n***\nbelow").should eq("above\n\nbelow")
    end

    it "converts bullet lists" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("- item one\n- item two").should eq("\u{2022} item one\n\u{2022} item two")
    end

    it "converts * bullet lists" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("* item").should eq("\u{2022} item")
    end

    it "preserves inline code" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("use `foo()` here").should eq("use `foo()` here")
    end

    it "preserves code blocks without language" do
      input = "```\nfoo\nbar\n```"
      Autobot::Channels::MarkdownToSlackMrkdwn.convert(input).should eq("```\nfoo\nbar\n```")
    end

    it "strips language hint from code blocks" do
      input = "```python\nprint('hi')\n```"
      Autobot::Channels::MarkdownToSlackMrkdwn.convert(input).should eq("```\nprint('hi')\n```")
    end

    it "does not apply formatting inside code blocks" do
      input = "```\n**not bold**\n```"
      Autobot::Channels::MarkdownToSlackMrkdwn.convert(input).should eq("```\n**not bold**\n```")
    end

    it "does not apply formatting inside inline code" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("`**not bold**`").should eq("`**not bold**`")
    end

    it "handles mixed formatting" do
      input = "**Bold** and _italic_ and `code`"
      expected = "*Bold* and _italic_ and `code`"
      Autobot::Channels::MarkdownToSlackMrkdwn.convert(input).should eq(expected)
    end

    it "preserves blockquotes" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("> quoted text").should eq("> quoted text")
    end

    it "preserves numbered lists" do
      input = "1. First\n2. Second"
      Autobot::Channels::MarkdownToSlackMrkdwn.convert(input).should eq("1. First\n2. Second")
    end

    it "strips output" do
      Autobot::Channels::MarkdownToSlackMrkdwn.convert("\n\nhello\n\n").should eq("hello")
    end

    it "handles bold header-like pattern" do
      input = "**Core Functions:**"
      Autobot::Channels::MarkdownToSlackMrkdwn.convert(input).should eq("*Core Functions:*")
    end

    it "handles complex real-world message" do
      input = "**My Purpose:**\n- Read and write files\n- Execute `shell` commands\n- Search the [web](https://example.com)"
      expected = "*My Purpose:*\n\u{2022} Read and write files\n\u{2022} Execute `shell` commands\n\u{2022} Search the <https://example.com|web>"
      Autobot::Channels::MarkdownToSlackMrkdwn.convert(input).should eq(expected)
    end
  end

  describe ".split_message" do
    it "returns single chunk for short messages" do
      Autobot::Channels::MarkdownToSlackMrkdwn.split_message("short").should eq(["short"])
    end

    it "splits messages exceeding Slack limit" do
      paragraph = "a" * 20_000
      text = "#{paragraph}\n\n#{paragraph}\n\n#{paragraph}"
      chunks = Autobot::Channels::MarkdownToSlackMrkdwn.split_message(text)
      chunks.size.should be > 1
      chunks.each(&.size.should(be <= 40_000))
    end
  end
end
