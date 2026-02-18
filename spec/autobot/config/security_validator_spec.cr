require "../../spec_helper"
require "file_utils"

describe Autobot::Config::SecurityValidator do
  describe "SECRET_PATTERNS" do
    it "detects AWS access key IDs" do
      content = "access_key_id: AKIAIOSFODNN7EXAMPLE"
      matched = Autobot::Config::SecurityValidator::SECRET_PATTERNS.any? do |pattern|
        content.match(pattern)
      end
      matched.should be_true
    end

    it "does not match short strings starting with AKIA" do
      content = "access_key_id: AKIA123"
      matched = Autobot::Config::SecurityValidator::SECRET_PATTERNS.any? do |pattern|
        content.match(pattern)
      end
      matched.should be_false
    end

    it "detects Anthropic API keys" do
      content = "api_key: sk-ant-api03-realkey123456789012345678"
      matched = Autobot::Config::SecurityValidator::SECRET_PATTERNS.any? do |pattern|
        content.match(pattern)
      end
      matched.should be_true
    end
  end
end
