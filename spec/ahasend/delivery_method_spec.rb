# frozen_string_literal: true

require "action_mailer"

# In-process delivery tests. The mailer class registers the delivery method
# on itself (class_attribute), so nothing here changes ActionMailer::Base;
# the full Rails lifecycle runs in a separate process (host_app_spec.rb).
RSpec.describe AhaSend::DeliveryMethod do
  let(:mailer_class) do
    Class.new(ActionMailer::Base) do
      add_delivery_method :ahasend, AhaSend::DeliveryMethod
      self.delivery_method = :ahasend
      self.ahasend_settings = { api_key: ApiHelpers::API_KEY, account_id: ApiHelpers::ACCOUNT_ID }

      def welcome(to, **opts)
        headers(opts[:headers]) if opts[:headers]
        mail(from: "Acme <noreply@acme.test>", to: to, subject: "Welcome", body: "Hi there")
      end
    end
  end

  def capture_notifications(name)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(name) { |*args| events << args.last }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
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
    end).to have_been_requested
  end

  it "returns a DeliveryResult from deliver!" do
    stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(queued_response("x@example.com"))

    result = described_class.new(settings).deliver!(mailer_class.welcome("x@example.com"))

    expect(result).to be_a(AhaSend::DeliveryResult)
    expect(result).to be_success
    expect(result).not_to be_replayed
    expect(result.status).to eq("queued")
    expect(result.messages.map(&:recipient)).to eq(["x@example.com"])
  end

  it "reports a replayed delivery" do
    stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(api_fixture("replayed_202"))

    expect(described_class.new(settings).deliver!(mailer_class.welcome("user@example.com"))).to be_replayed
  end

  it "raises DeliveryError when the API reports a recipient error" do
    stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(api_fixture("create_message_partial_error_202"))

    expect { described_class.new(settings).deliver!(mailer_class.welcome(%w[ok@example.com bounced@example.com])) }
      .to raise_error(AhaSend::DeliveryError,
                      "AhaSend rejected 1 of 2 recipient(s): bounced@example.com: recipient is suppressed") { |e|
        expect(e.result.failed.map(&:recipient)).to eq(["bounced@example.com"])
      }
  end

  it "raises UnexpectedResponseError and keeps Mail's Message-ID when a 2xx is malformed" do
    stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(status: 202, body: '{"data":[{}]}')
    message = mailer_class.welcome("u@example.com").message
    original_id = message.message_id

    expect { described_class.new(settings).deliver!(message) }.to raise_error(AhaSend::UnexpectedResponseError)
    expect(message.message_id).to eq(original_id)
  end

  it "propagates API errors" do
    stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(error_response(401, "bad key"))

    expect { mailer_class.welcome("u@example.com").deliver_now }.to raise_error(AhaSend::AuthenticationError)
  end

  it "raises MessageError before making any request when the message cannot be represented" do
    stub = stub_request(:post, /ahasend/)
    message = mailer_class.welcome("u@example.com", headers: { "AhaSend-Substitutions" => '{"name":"Ann"}' })
    message.cc = "archive@example.com"

    expect { message.deliver_now }.to raise_error(AhaSend::MessageError, /substitutions/)
    expect(stub).not_to have_been_requested
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

  it "validates settings lazily: building the delivery method never raises, delivering does" do
    delivery_method = nil
    expect { delivery_method = described_class.new(max_retries: -1) }.not_to raise_error
    expect { delivery_method.deliver!(mailer_class.welcome("u@example.com")) }
      .to raise_error(AhaSend::ConfigurationError, /api_key/)
    expect { described_class.new(settings(max_retries: -1)).deliver!(mailer_class.welcome("u@example.com")) }
      .to raise_error(AhaSend::ConfigurationError, /max_retries/)
  end

  describe "deliver.ahasend notification" do
    it "carries Rails' Message-ID next to AhaSend's IDs and statuses, without content or credentials" do
      stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(queued_response("n@example.com"))
      message = mailer_class.welcome("n@example.com").message
      rails_id = message.message_id

      events = capture_notifications("deliver.ahasend") { described_class.new(settings).deliver!(message) }

      expect(events.size).to eq(1)
      expect(events.first).to eq(
        mail_message_id: rails_id, endpoint: :messages, sandbox: false,
        message_ids: ["<n-example.com@ahasend.com>"],
        recipients: [{ email: "n@example.com", status: "queued", id: "<n-example.com@ahasend.com>", error: nil }],
        replayed: false
      )
    end

    it "records the exception when delivery fails" do
      stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(error_response(400, "bad"))

      events = capture_notifications("deliver.ahasend") do
        expect { described_class.new(settings).deliver!(mailer_class.welcome("n@example.com")) }
          .to raise_error(AhaSend::ValidationError)
      end

      expect(events.first[:exception]).to eq(["AhaSend::ValidationError", "AhaSend API error 400: bad"])
    end
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
