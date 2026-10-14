# frozen_string_literal: true

# Checks every payload shape the gem can build against the request contract
# extracted from AhaSend's OpenAPI spec (spec/fixtures/api), so a payload the
# API would reject or misread fails here rather than in production.
RSpec.describe "API request contract" do # rubocop:disable RSpec/DescribeClass
  def base_mail
    Mail.new do
      from "Sender <sender@example.com>"
      to "user@example.com"
      subject "Hello"
      text_part { body "text" }
      html_part do
        content_type "text/html; charset=UTF-8"
        body "<p>html</p>"
      end
    end
  end

  def with_everything(mail)
    mail.reply_to = "help@example.com"
    mail["X-Campaign"] = "spring"
    mail.add_file(filename: "report.pdf", content: "%PDF fake")
    mail.attachments.inline["logo.png"] = "\x89PNG"
    mail.ahasend.tags = %w[a b]
    mail.ahasend.tracking = { open: true, click: false }
    mail.ahasend.retention = { metadata: 7, data: 0 }
    mail.ahasend.schedule = { first_attempt: "2026-01-01T00:00:00Z", expires: "2026-01-02T00:00:00Z" }
    mail.ahasend.sandbox = true
    mail.ahasend.sandbox_result = "deliver"
    mail
  end

  # Builds a payload and asserts it against the endpoint's contract.
  def expect_conforming(mail)
    built = AhaSend::MessagePayload.build(mail)
    endpoint = request_contract.dig("endpoints", built.endpoint.to_s)

    expect(built.payload.keys - endpoint["properties"]).to be_empty
    expect(endpoint["required"] - built.payload.keys).to be_empty
    endpoint["arrays"].each do |field, limits|
      next unless built.payload.key?(field)

      expect(built.payload[field].size).to be >= limits.fetch("minItems", 0)
      expect(built.payload[field].size).to be <= limits.fetch("maxItems", Float::INFINITY)
    end
    if built.conversation?
      total = built.payload.values_at("to", "cc", "bcc").compact.sum(&:size)
      expect(total).to be <= request_contract.dig("rules", "conversation_total_recipients", "max")
    end
    expect_nested_conforming(built.payload)
    built
  end

  def expect_nested_conforming(payload)
    schemas = request_contract["schemas"]
    addresses = [payload["from"], payload["reply_to"], *payload.values_at("recipients", "to", "cc", "bcc").flatten].compact
    addresses.each { |address| expect(address.keys - schemas.dig("Recipient", "properties")).to be_empty }

    { "tracking" => "Tracking", "retention" => "Retention", "schedule" => "MessageSchedule" }.each do |field, schema|
      expect(payload[field].keys - schemas.dig(schema, "properties")).to be_empty if payload[field]
    end

    Array(payload["attachments"]).each do |attachment|
      expect(attachment.keys - schemas.dig("Attachment", "properties")).to be_empty
      expect(schemas.dig("Attachment", "required") - attachment.keys).to be_empty
      next unless attachment.key?("content_id")

      expect(attachment["content_id"]).to match(Regexp.new(request_contract.dig("rules", "attachment_content_id", "pattern")))
    end
  end

  it "conforms for a plain send" do
    expect(expect_conforming(base_mail).endpoint).to eq(:messages)
  end

  it "conforms for a send using every field and option" do
    mail = with_everything(base_mail)
    mail.ahasend.substitutions = { "name" => "Ann" }

    expect(expect_conforming(mail).endpoint).to eq(:messages)
  end

  it "conforms for a conversation send with Cc and Bcc" do
    mail = with_everything(base_mail)
    mail.cc = "cc@example.com"
    mail.bcc = "bcc@example.com"

    expect(expect_conforming(mail).endpoint).to eq(:conversation)
  end

  it "conforms for a Bcc-only send" do
    mail = base_mail
    mail.to = nil
    mail.bcc = "bcc@example.com"

    expect(expect_conforming(mail).endpoint).to eq(:messages)
  end

  it "conforms for an envelope-redirected send" do
    mail = base_mail
    mail.cc = "cc@example.com"
    mail.smtp_envelope_to = "test-inbox@example.com"

    expect(expect_conforming(mail).endpoint).to eq(:messages)
  end

  it "conforms at the recipient limits, and the gem refuses to build past them" do
    to_only = base_mail
    to_only.to = Array.new(100) { |i| "r#{i}@example.com" }
    expect(expect_conforming(to_only).payload["recipients"].size).to eq(100)

    conversation = base_mail
    conversation.to = Array.new(49) { |i| "r#{i}@example.com" }
    conversation.cc = "cc@example.com"
    expect(expect_conforming(conversation)).to be_conversation

    conversation.bcc = "one-too-many@example.com"
    expect { AhaSend::MessagePayload.build(conversation) }.to raise_error(AhaSend::MessageError, /at most 50/)
  end

  it "records where the contract came from" do
    expect(request_contract["source"]).to include("repository" => "https://github.com/AhaSend/docs", "commit" => "3add235")
  end
end
