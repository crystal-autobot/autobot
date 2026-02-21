require "../../spec_helper"

describe Autobot::Channels::MarkdownToTelegramHTML do
  describe ".convert" do
    it "returns empty string for empty input" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("").should eq("")
    end

    it "passes plain text through" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("Hello world").should eq("Hello world")
    end

    it "escapes HTML special characters" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("a & b < c > d").should eq("a &amp; b &lt; c &gt; d")
    end

    it "escapes double quotes" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("say \"hello\"").should eq("say &quot;hello&quot;")
    end

    it "converts **bold** to <b> tags" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("**bold text**").should eq("<b>bold text</b>")
    end

    it "converts __bold__ to <b> tags" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("__bold text__").should eq("<b>bold text</b>")
    end

    it "converts _italic_ to <i> tags" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("_italic text_").should eq("<i>italic text</i>")
    end

    it "does not convert _underscores_ inside words" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("snake_case_name").should eq("snake_case_name")
    end

    it "converts ~~strikethrough~~ to <s> tags" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("~~deleted~~").should eq("<s>deleted</s>")
    end

    it "converts [text](url) to <a> tags" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("[click](https://example.com)").should eq(
        %(<a href="https://example.com">click</a>)
      )
    end

    it "converts inline code to <code> tags" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("use `foo()` here").should eq("use <code>foo()</code> here")
    end

    it "escapes HTML inside inline code" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("use `a<b>c` here").should eq("use <code>a&lt;b&gt;c</code> here")
    end

    it "converts code blocks to <pre><code> tags" do
      input = "```\nfoo\nbar\n```"
      Autobot::Channels::MarkdownToTelegramHTML.convert(input).should eq("<pre><code>foo\nbar\n</code></pre>")
    end

    it "converts code blocks with language to <pre><code class> tags" do
      input = "```python\nprint('hi')\n```"
      Autobot::Channels::MarkdownToTelegramHTML.convert(input).should eq(
        "<pre><code class=\"language-python\">print('hi')\n</code></pre>"
      )
    end

    it "escapes HTML inside code blocks" do
      input = "```\na<b>c\n```"
      Autobot::Channels::MarkdownToTelegramHTML.convert(input).should eq("<pre><code>a&lt;b&gt;c\n</code></pre>")
    end

    it "does not apply formatting inside code blocks" do
      input = "```\n**not bold**\n```"
      Autobot::Channels::MarkdownToTelegramHTML.convert(input).should eq("<pre><code>**not bold**\n</code></pre>")
    end

    it "does not apply formatting inside inline code" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("`**not bold**`").should eq("<code>**not bold**</code>")
    end

    it "converts headers to bold" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("# Title").should eq("<b>Title</b>")
    end

    it "converts multi-level headers to bold" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("### Subtitle").should eq("<b>Subtitle</b>")
    end

    it "strips blockquotes" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("> quoted text").should eq("quoted text")
    end

    it "strips horizontal rules" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("above\n---\nbelow").should eq("above\n\nbelow")
    end

    it "strips *** horizontal rules" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("above\n***\nbelow").should eq("above\n\nbelow")
    end

    it "strips ___ horizontal rules" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("above\n___\nbelow").should eq("above\n\nbelow")
    end

    it "converts bullet lists with -" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("- item one\n- item two").should eq("\u{2022} item one\n\u{2022} item two")
    end

    it "converts bullet lists with *" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("* item").should eq("\u{2022} item")
    end

    it "preserves underscore runs (fill-in-the-blank)" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("Pies jest ______ (duży).").should eq("Pies jest ______ (duży).")
    end

    it "preserves long underscore runs" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("Fill in: ________").should eq("Fill in: ________")
    end

    it "handles mixed formatting" do
      input = "**Bold** and _italic_ and `code`"
      expected = "<b>Bold</b> and <i>italic</i> and <code>code</code>"
      Autobot::Channels::MarkdownToTelegramHTML.convert(input).should eq(expected)
    end

    it "handles bold with special chars inside" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("**a & b**").should eq("<b>a &amp; b</b>")
    end

    it "leaves numbered lists as plain text" do
      input = "1. First\n2. Second"
      Autobot::Channels::MarkdownToTelegramHTML.convert(input).should eq("1. First\n2. Second")
    end

    it "escapes quotes in link URLs to prevent attribute injection" do
      input = "[click](url\"onclick=\"alert)"
      result = Autobot::Channels::MarkdownToTelegramHTML.convert(input)
      # Quotes in URL are escaped, staying inside the href value
      result.should eq(%(<a href="url&quot;onclick=&quot;alert">click</a>))
    end

    it "strips output" do
      Autobot::Channels::MarkdownToTelegramHTML.convert("\n\nhello\n\n").should eq("hello")
    end
  end

  describe ".valid_html?" do
    it "returns true for valid HTML" do
      Autobot::Channels::MarkdownToTelegramHTML.valid_html?("<b>bold</b>").should be_true
    end

    it "returns true for nested HTML" do
      Autobot::Channels::MarkdownToTelegramHTML.valid_html?("<b><i>bold italic</i></b>").should be_true
    end

    it "returns true for plain text" do
      Autobot::Channels::MarkdownToTelegramHTML.valid_html?("no tags").should be_true
    end

    it "returns false for unclosed tags" do
      Autobot::Channels::MarkdownToTelegramHTML.valid_html?("<b>open").should be_false
    end

    it "returns false for mismatched tags" do
      Autobot::Channels::MarkdownToTelegramHTML.valid_html?("<b>text</i>").should be_false
    end

    it "returns false for extra closing tag" do
      Autobot::Channels::MarkdownToTelegramHTML.valid_html?("text</b>").should be_false
    end

    it "returns true for code with attributes" do
      Autobot::Channels::MarkdownToTelegramHTML.valid_html?("<pre><code class=\"language-python\">x</code></pre>").should be_true
    end
  end

  describe ".strip_html" do
    it "removes all supported HTML tags" do
      Autobot::Channels::MarkdownToTelegramHTML.strip_html("<b>bold</b> <i>italic</i>").should eq("bold italic")
    end

    it "removes tags with attributes" do
      Autobot::Channels::MarkdownToTelegramHTML.strip_html(%(<a href="url">link</a>)).should eq("link")
    end

    it "preserves non-tag text" do
      Autobot::Channels::MarkdownToTelegramHTML.strip_html("plain text").should eq("plain text")
    end
  end

  describe ".split_message" do
    it "returns single chunk for short messages" do
      Autobot::Channels::MarkdownToTelegramHTML.split_message("short").should eq(["short"])
    end

    it "splits long messages by paragraphs" do
      paragraph = "a" * 2000
      text = "#{paragraph}\n\n#{paragraph}\n\n#{paragraph}"
      chunks = Autobot::Channels::MarkdownToTelegramHTML.split_message(text)
      chunks.size.should be > 1
      chunks.each(&.size.should(be <= 4096))
    end

    it "splits long single paragraphs by lines" do
      line = "a" * 100
      lines = Array.new(50) { line }
      text = lines.join("\n")
      chunks = Autobot::Channels::MarkdownToTelegramHTML.split_message(text)
      chunks.size.should be > 1
      chunks.each(&.size.should(be <= 4096))
    end

    it "preserves all content across chunks" do
      paragraph = "a" * 2000
      text = "#{paragraph}\n\n#{paragraph}\n\n#{paragraph}"
      chunks = Autobot::Channels::MarkdownToTelegramHTML.split_message(text)
      chunks.join("\n\n").should eq(text)
    end
  end
end
