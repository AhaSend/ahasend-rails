# frozen_string_literal: true

# The Rails delivery lifecycle, exercised in a real Rails application booted
# in a separate process (spec/scripts/host_app.rb): Rails first, then the
# gem's public entry point, exactly as Bundler.require loads it.
RSpec.describe "Rails host application" do # rubocop:disable RSpec/DescribeClass
  def scenario(name)
    result = Subprocess.host_app_results.fetch("scenarios").fetch(name)
    raise "scenario #{name} failed: #{result["error"]}" if result.is_a?(Hash) && result.key?("error")

    result
  end

  it "loads the Railtie through the public entry point and applies config.action_mailer settings" do
    expect(scenario("railtie")).to eq(
      "registered" => true, "delivery_method" => "ahasend",
      "settings" => { "api_key" => "aha-sk-host", "account_id" => "acc-1", "max_retries" => 0, "sandbox" => true }
    )
  end

  it "delivers with deliver_now, applying options set inside the mailer action and the settings defaults" do
    expect(scenario("deliver_now")).to eq(
      "requests" => 1, "path" => "/v2/accounts/acc-1/messages", "recipients" => ["new@user.test"],
      "options" => { "tags" => ["welcome"], "tracking" => { "open" => true }, "sandbox" => true },
      "message_id" => "0@ahasend.test"
    )
  end

  it "enqueues and performs deliver_later through the test queue adapter, keeping in-action options" do
    expect(scenario("deliver_later")).to eq(
      "adapter" => "ActiveJob::QueueAdapters::TestAdapter", "job" => "ActionMailer::MailDeliveryJob",
      "requests" => 1, "recipients" => ["later@user.test"],
      "options" => { "tags" => ["welcome"], "tracking" => { "open" => true } }, "idempotency_key_sent" => true
    )
  end

  it "sends to the recipients an interceptor rewrote" do
    expect(scenario("interceptor_to")).to eq("recipients" => ["qa@acme.test"])
  end

  it "honours an interceptor's smtp_envelope_to and never reaches the header recipients" do
    expect(scenario("interceptor_envelope")).to eq(
      "path" => "/v2/accounts/acc-1/messages", "recipients" => ["test-inbox@acme.test"]
    )
  end

  it "notifies observers with AhaSend's Message-ID" do
    expect(scenario("observer")).to eq("observed_message_id" => "0@ahasend.test")
  end

  it "makes no request when perform_deliveries is false" do
    expect(scenario("perform_deliveries_false")).to eq("requests" => 0)
  end

  it "swallows API errors when raise_delivery_errors is false" do
    expect(scenario("raise_delivery_errors_false")).to eq("requests" => 1, "raised" => false)
  end

  it "raises API errors when raise_delivery_errors is true" do
    expect(scenario("raise_delivery_errors_true")).to eq("raised" => "AhaSend::ValidationError")
  end

  it "applies per-message delivery_method_options" do
    expect(scenario("delivery_method_options")).to eq("path" => "/v2/accounts/acc-2/messages")
  end

  it "emits deliver.ahasend linking Rails' Message-ID to AhaSend's" do
    result = scenario("notifications")

    expect(result["ahasend_mail_message_id"]).to eq(result["rails_message_id"])
    expect(result["ahasend_message_ids"]).to eq(["<0@ahasend.test>"])
    expect(result["final_message_id"]).to eq("0@ahasend.test")
    expect(result["payload_keys"]).to eq(%w[endpoint mail_message_id message_ids recipients replayed sandbox])
  end
end
