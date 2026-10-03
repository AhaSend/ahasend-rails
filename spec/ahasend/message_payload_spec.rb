# frozen_string_literal: true

RSpec.describe AhaSend::MessagePayload do
  def build(mail, defaults: {})
    described_class.build(mail, defaults: defaults)
  end

  def simple_mail(**overrides)
    mail = Mail.new do
      from "Sender <sender@example.com>"
      to "user@example.com"
      subject "Hello"
      body "Plain body"
    end
    overrides.each { |k, v| mail.public_send(:"#{k}=", v) }
    mail
  end

  describe "endpoint selection" do
    it "uses /messages with recipients[] when there is no cc/bcc" do
      built = build(simple_mail(to: ["a@example.com", "Bee <b@example.com>"]))

      expect(built).not_to be_conversation
      expect(built.payload["recipients"]).to eq([{ "email" => "a@example.com" },
                                                 { "email" => "b@example.com", "name" => "Bee" }])
      expect(built.payload).not_to include("to", "cc", "bcc")
    end

    it "uses /messages/conversation with to/cc/bcc when cc is present" do
      built = build(simple_mail(cc: "cc@example.com"))

      expect(built).to be_conversation
      expect(built.payload["to"]).to eq([{ "email" => "user@example.com" }])
      expect(built.payload["cc"]).to eq([{ "email" => "cc@example.com" }])
      expect(built.payload).not_to include("recipients", "bcc")
    end

    it "uses /messages/conversation when only bcc is present" do
      built = build(simple_mail(bcc: "hidden@example.com"))

      expect(built).to be_conversation
      expect(built.payload["bcc"]).to eq([{ "email" => "hidden@example.com" }])
      expect(built.payload).not_to include("cc")
    end
  end

  describe "addresses and subject" do
    it "maps from with display name, subject and reply_to" do
      built = build(simple_mail(reply_to: "Support <help@example.com>"))

      expect(built.payload["from"]).to eq("email" => "sender@example.com", "name" => "Sender")
      expect(built.payload["subject"]).to eq("Hello")
      expect(built.payload["reply_to"]).to eq("email" => "help@example.com", "name" => "Support")
    end

    it "omits reply_to when absent" do
      expect(build(simple_mail).payload).not_to include("reply_to")
    end
  end

  describe "bodies" do
    it "sends a plain-text single-part body as text_content" do
      payload = build(simple_mail).payload
      expect(payload["text_content"]).to eq("Plain body")
      expect(payload).not_to include("html_content", "amp_content")
    end

    it "sends an html single-part body as html_content" do
      mail = simple_mail
      mail.content_type = "text/html; charset=UTF-8"
      mail.body = "<p>Hi</p>"
      payload = build(mail).payload
      expect(payload["html_content"]).to eq("<p>Hi</p>")
      expect(payload).not_to include("text_content")
    end

    it "sends both parts of a multipart/alternative mail" do
      mail = Mail.new do
        from "sender@example.com"
        to "user@example.com"
        subject "Multi"
        text_part { body "text version" }
        html_part do
          content_type "text/html; charset=UTF-8"
          body "<b>html version</b>"
        end
      end
      payload = build(mail).payload
      expect(payload["text_content"]).to eq("text version")
      expect(payload["html_content"]).to eq("<b>html version</b>")
    end

    it "picks up an AMP part" do
      mail = simple_mail
      mail.add_part(Mail::Part.new do
        content_type "text/x-amp-html"
        body "<html ⚡4email></html>"
      end)
      expect(build(mail).payload["amp_content"]).to eq("<html ⚡4email></html>")
    end

    it "preserves non-ASCII text" do
      mail = simple_mail
      mail.body = "Grüße — こんにちは"
      expect(build(mail).payload["text_content"]).to eq("Grüße — こんにちは")
    end
  end

  describe "attachments" do
    it "base64-encodes regular attachments" do
      mail = simple_mail
      mail.add_file(filename: "report.pdf", content: "%PDF-1.4 fake")
      att = build(mail).payload["attachments"].first

      expect(att).to eq("file_name" => "report.pdf", "content_type" => "application/pdf",
                        "data" => Base64.strict_encode64("%PDF-1.4 fake"), "base64" => true)
    end

    it "marks inline images with content_id and disposition" do
      mail = simple_mail
      mail.attachments.inline["logo.png"] = "\x89PNG\r\nfake"
      att = build(mail).payload["attachments"].first

      expect(att["content_disposition"]).to eq("inline")
      expect(att["content_id"]).to match(/\A[^<>]+\z/)
      expect(att["file_name"]).to eq("logo.png")
      expect(att["content_type"]).to eq("image/png")
    end

    it "still finds the text body on a mail with attachments" do
      mail = simple_mail
      mail.add_file(filename: "a.txt", content: "attached")
      payload = build(mail).payload
      expect(payload["text_content"]).to eq("Plain body")
      expect(payload["attachments"].size).to eq(1)
    end
  end

  describe "custom headers" do
    it "forwards unknown headers and drops standard and AhaSend-* ones" do
      mail = simple_mail
      mail["X-Campaign"] = "spring"
      mail["List-Unsubscribe"] = "<mailto:u@example.com>"
      mail["AhaSend-Tags"] = "a"
      headers = build(mail).payload["headers"]

      expect(headers).to eq("X-Campaign" => "spring", "List-Unsubscribe" => "<mailto:u@example.com>")
    end

    it "omits headers when there are none to forward" do
      expect(build(simple_mail).payload).not_to include("headers")
    end
  end

  describe "AhaSend-* option headers" do
    it "parses every supported header" do
      mail = simple_mail
      mail["AhaSend-Tags"] = "welcome, onboarding ,"
      mail["AhaSend-Track-Opens"] = "true"
      mail["AhaSend-Track-Clicks"] = "no"
      mail["AhaSend-Retention-Metadata"] = "30"
      mail["AhaSend-Retention-Data"] = "0"
      mail["AhaSend-Schedule-First-Attempt"] = "2026-01-01T00:00:00Z"
      mail["AhaSend-Sandbox"] = "yes"
      mail["AhaSend-Sandbox-Result"] = "bounce"
      mail["AhaSend-Idempotency-Key"] = "key-1"
      mail["AhaSend-Substitutions"] = '{"first_name":"Ann"}'

      built = build(mail)
      expect(built.payload).to include(
        "tags" => %w[welcome onboarding],
        "tracking" => { open: true, click: false },
        "retention" => { metadata: 30, data: 0 },
        "schedule" => { first_attempt: "2026-01-01T00:00:00Z" },
        "sandbox" => true,
        "sandbox_result" => "bounce",
        "substitutions" => { "first_name" => "Ann" }
      )
      expect(built.idempotency_key).to eq("key-1")
      expect(built.payload).not_to include("headers")
    end

    it "sets only the tracking flag that was given" do
      mail = simple_mail
      mail["AhaSend-Track-Clicks"] = "1"
      expect(build(mail).payload["tracking"]).to eq(click: true)
    end
  end

  describe "message.ahasend options and settings defaults" do
    it "lets message.ahasend override headers, and headers override settings" do
      mail = simple_mail
      mail["AhaSend-Tags"] = "from-header"
      mail["AhaSend-Sandbox"] = "false"
      mail.ahasend.tags = %w[from-ruby]
      mail.ahasend.tracking = { open: false }

      payload = build(mail, defaults: { sandbox: true, tags: %w[from-settings], retention: { data: 1 } }).payload

      expect(payload["tags"]).to eq(%w[from-ruby])
      expect(payload["sandbox"]).to be(false)
      expect(payload["tracking"]).to eq(open: false)
      expect(payload["retention"]).to eq(data: 1)
    end

    it "ignores non-option settings keys" do
      payload = build(simple_mail, defaults: { api_key: "k", account_id: "a", sandbox: true }).payload
      expect(payload.keys).not_to include("api_key", "account_id")
      expect(payload["sandbox"]).to be(true)
    end

    it "omits option fields entirely when unset" do
      payload = build(simple_mail).payload
      expect(payload.keys).to contain_exactly("from", "recipients", "subject", "text_content")
    end
  end
end
