require "../../spec_helper"

private def params(value : String) : Hash(String, JSON::Any)
  {"input" => JSON::Any.new(value)}
end

describe Autobot::Tools::ConfirmationStore do
  it "issues a short unambiguous code and redeems it once" do
    store = Autobot::Tools::ConfirmationStore.new
    pending = store.request("telegram:1", "exec", params("rm x"))

    pending.code.size.should eq(4)
    pending.code.each_char { |char| Autobot::Tools::ConfirmationStore::CODE_ALPHABET.includes?(char).should be_true }
    store.pending?("telegram:1").should be_true

    taken = store.take("telegram:1", " #{pending.code.downcase} ")
    taken.try(&.name).should eq("exec")
    taken.try(&.params).should eq(params("rm x"))
    store.take("telegram:1", pending.code).should be_nil
  end

  it "ignores wrong codes and other sessions" do
    store = Autobot::Tools::ConfirmationStore.new
    pending = store.request("telegram:1", "exec", params("x"))

    store.take("telegram:1", "NOPE").should be_nil
    store.take("telegram:2", pending.code).should be_nil
    store.pending?("telegram:1").should be_true
  end

  it "drops an expired code" do
    store = Autobot::Tools::ConfirmationStore.new
    pending = store.request("telegram:1", "exec", params("x"), ttl: -1.second)

    store.take("telegram:1", pending.code).should be_nil
    store.pending?("telegram:1").should be_false
  end

  it "keeps only the latest request per session" do
    store = Autobot::Tools::ConfirmationStore.new
    first = store.request("telegram:1", "exec", params("a"))
    second = store.request("telegram:1", "exec", params("b"))

    store.take("telegram:1", first.code).should be_nil
    store.take("telegram:1", second.code).try(&.params).should eq(params("b"))
  end
end
