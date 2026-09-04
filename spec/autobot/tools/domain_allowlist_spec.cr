require "../../spec_helper"

describe Autobot::Tools::DomainAllowlist do
  it "allows every host when empty" do
    Autobot::Tools::DomainAllowlist.new([] of String).allows?("anything.example").should be_true
  end

  it "matches exact hosts case-insensitively" do
    list = Autobot::Tools::DomainAllowlist.new(["Example.com"])
    list.allows?("example.com").should be_true
    list.allows?("EXAMPLE.COM").should be_true
    list.allows?("www.example.com").should be_false
    list.allows?("example.com.evil").should be_false
  end

  it "matches subdomains and the apex for wildcard entries" do
    list = Autobot::Tools::DomainAllowlist.new(["*.strava.com"])
    list.allows?("strava.com").should be_true
    list.allows?("www.strava.com").should be_true
    list.allows?("api.eu.strava.com").should be_true
    list.allows?("notstrava.com").should be_false
    list.allows?("strava.com.evil").should be_false
  end

  it "ignores blank entries" do
    Autobot::Tools::DomainAllowlist.new(["", " "]).allows?("anything.example").should be_true
  end
end
