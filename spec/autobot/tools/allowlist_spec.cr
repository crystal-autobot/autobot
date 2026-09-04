require "../../spec_helper"

describe Autobot::Tools::Allowlist do
  it "allows everything when empty" do
    list = Autobot::Tools::Allowlist.all
    list.restricted?.should be_false
    list.allows?("anything").should be_true
  end

  it "matches exact names and prefix patterns only" do
    list = Autobot::Tools::Allowlist.new(["read_file", "ha_*"])

    list.restricted?.should be_true
    list.allows?("read_file").should be_true
    list.allows?("ha_get_state").should be_true
    list.allows?("write_file").should be_false
    list.allows?("read_file_extra").should be_false
  end
end
