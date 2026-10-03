# frozen_string_literal: true

require "action_mailer"

RSpec.describe AhaSend::DeliveryMethod do
  let(:mailer_class) do
    Class.new(ActionMailer::Base) do
      self.delivery_method = :ahasend
      self.ahasend_settings = { api_key: ApiHelpers::API_KEY, account_id: ApiHelpers::ACCOUNT_ID }

      def welcome(to, **opts)
        headers(opts[:headers]) if opts[:headers]
        mail(from: "Acme <noreply@acme.test>", to: to, subject: "Welcome", body: "Hi there")
      end
    end
  end

  before do
    ActionMailer::Base.add_delivery_method(:ahasend, described_class) unless ActionMailer::Base.delivery_methods[:ahasend]
    ActionMailer::Base.raise_delivery_errors = true
  end

  it "delivers through the API and writes the Message-ID back" do
    stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(queued_response("someone@example.com"))

    message = mailer_class.welcome("someone@example.com")
    message.deliver_now

    expect(stub.with do |req|
      body = request_json(req)
      body["from"] == { "email" => "noreply@acme.test", "name" => "Acme" } &&
        body["recipients"] == [{ "email" => "someone@example.com" }] &&
        body["text_content"] == "Hi there"
    end).to have_been_requested.once
    expect(message.message_id).to eq("someone-example.com@ahasend.com")
  end

  it "routes mails with cc through the conversation endpoint" do
    stub = stub_request(:post, ApiHelpers::CONVERSATION_URL).to_return(queued_response("a@example.com", "c@example.com"))

    message = mailer_class.welcome("a@example.com")
    message.cc = "c@example.com"
    message.deliver_now

    expect(stub).to have_been_requested.once
  end

  it "passes ActionMailer headers through as AhaSend options" do
    stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(queued_response)

    mailer_class.welcome("user@example.com", headers: { "AhaSend-Tags" => "signup", "AhaSend-Track-Opens" => "true" })
                .deliver_now

    expect(stub.with do |r|
      request_json(r).slice("tags", "tracking") == { "tags" => ["signup"], "tracking" => { "open" => true } }
    end)
      .to have_been_requested
  end

  it "returns a DeliveryResult from deliver!" do
    stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(queued_response("x@example.com"))

    result = described_class.new(settings).deliver!(mailer_class.welcome("x@example.com"))

    expect(result).to be_a(AhaSend::DeliveryResult)
    expect(result).to be_success
    expect(result.status).to eq("queued")
    expect(result.messages.map(&:recipient)).to eq(["x@example.com"])
  end

  it "raises DeliveryError when the API reports a recipient error" do
    body = { "object" => "list", "data" => [
      { "object" => "message", "id" => "<ok@ahasend.com>", "status" => "queued", "recipient" => { "email" => "ok@example.com" } },
      { "object" => "message", "id" => nil, "status" => "error", "recipient" => { "email" => "bad@example.com" },
        "error" => "suppressed" }
    ] }
    stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(status: 202, body: JSON.generate(body))

    expect { described_class.new(settings).deliver!(mailer_class.welcome(%w[ok@example.com bad@example.com])) }
      .to raise_error(AhaSend::DeliveryError, "AhaSend rejected 1 of 2 recipient(s): bad@example.com: suppressed") { |e|
        expect(e.result.failed.map(&:recipient)).to eq(["bad@example.com"])
      }
  end

  it "propagates API errors" do
    stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(error_response(401, "bad key"))

    expect { mailer_class.welcome("u@example.com").deliver_now }.to raise_error(AhaSend::AuthenticationError)
  end

  it "applies settings-level defaults such as sandbox and forwards client settings" do
    mailer = Class.new(mailer_class) do
      self.ahasend_settings = { api_key: ApiHelpers::API_KEY, account_id: ApiHelpers::ACCOUNT_ID,
                                sandbox: true, base_url: "https://staging.ahasend.test" }
    end
    stub = stub_request(:post, "https://staging.ahasend.test/v2/accounts/#{ApiHelpers::ACCOUNT_ID}/messages")
           .to_return(queued_response)

    mailer.welcome("u@example.com").deliver_now

    expect(stub.with { |r| request_json(r)["sandbox"] == true }).to have_been_requested
  end

  it "raises ConfigurationError when settings are missing" do
    expect { described_class.new({}).deliver!(mailer_class.welcome("u@example.com")) }
      .to raise_error(AhaSend::ConfigurationError)
  end

  it "works with the plain Mail gem" do
    stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(queued_response("p@example.com"))

    mail = Mail.new do
      from "me@example.com"
      to "p@example.com"
      subject "Plain"
      body "no rails here"
    end
    mail.delivery_method(described_class, settings)
    mail.deliver!

    expect(mail.message_id).to eq("p-example.com@ahasend.com")
  end
end
