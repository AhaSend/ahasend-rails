# frozen_string_literal: true

require "base64"

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

  def recipient_emails(built)
    built.payload.fetch("recipients").map { |r| r["email"] }
  end

  describe "endpoint selection" do
    it "uses /messages with recipients[] when there is no cc/bcc" do
      built = build(simple_mail(to: ["a@example.com", "Bee <b@example.com>"]))

      expect(built).not_to be_conversation
      expect(built.endpoint).to eq(:messages)
      expect(built.payload["recipients"]).to eq([{ "email" => "a@example.com" },
                                                 { "email" => "b@example.com", "name" => "Bee" }])
      expect(built.payload).not_to include("to", "cc", "bcc")
    end

    it "uses /messages/conversation with to/cc when cc is present" do
      built = build(simple_mail(cc: "cc@example.com"))

      expect(built).to be_conversation
      expect(built.endpoint).to eq(:conversation)
      expect(built.payload["to"]).to eq([{ "email" => "user@example.com" }])
      expect(built.payload["cc"]).to eq([{ "email" => "cc@example.com" }])
      expect(built.payload).not_to include("recipients", "bcc")
    end

    it "uses /messages/conversation for To plus Bcc" do
      built = build(simple_mail(bcc: "hidden@example.com"))

      expect(built).to be_conversation
      expect(built.payload["to"]).to eq([{ "email" => "user@example.com" }])
      expect(built.payload["bcc"]).to eq([{ "email" => "hidden@example.com" }])
      expect(built.payload).not_to include("cc")
    end

    it "sends a Bcc-only mail to /messages, one individual message per Bcc address" do
      built = build(simple_mail(to: nil, bcc: ["one@example.com", "Two <two@example.com>"]))

      expect(built).not_to be_conversation
      expect(built.payload["recipients"]).to eq([{ "email" => "one@example.com" },
                                                 { "email" => "two@example.com", "name" => "Two" }])
      expect(built.payload).not_to include("to", "bcc")
    end

    it "rejects Cc without any To recipient" do
      expect { build(simple_mail(to: nil, cc: "cc@example.com")) }
        .to raise_error(AhaSend::MessageError, /Cc but no To/)
    end

    it "rejects a message without recipients" do
      expect { build(simple_mail(to: nil)) }.to raise_error(AhaSend::MessageError, /no recipients/)
    end

    it "rejects a message without From" do
      expect { build(simple_mail(from: nil)) }.to raise_error(AhaSend::MessageError, /no From/)
    end
  end

  describe "recipient limits" do
    def addresses(count, prefix = "r") = Array.new(count) { |i| "#{prefix}#{i}@example.com" }

    it "accepts 100 recipients on /messages and rejects 101 before sending" do
      expect(build(simple_mail(to: addresses(100))).payload["recipients"].size).to eq(100)
      expect { build(simple_mail(to: addresses(101))) }
        .to raise_error(AhaSend::MessageError, /101 recipients; AhaSend accepts at most 100/)
    end

    it "applies the 100 limit to Bcc-only mail and to an envelope override" do
      expect { build(simple_mail(to: nil, bcc: addresses(101))) }.to raise_error(AhaSend::MessageError, /at most 100/)

      redirected = simple_mail
      redirected.smtp_envelope_to = addresses(101, "inbox")
      expect { build(redirected) }.to raise_error(AhaSend::MessageError, /at most 100/)
    end

    it "accepts 50 To+Cc+Bcc recipients on the conversation endpoint and rejects 51" do
      expect(build(simple_mail(to: addresses(30), cc: addresses(10, "c"), bcc: addresses(10, "b")))).to be_conversation
      expect { build(simple_mail(to: addresses(30), cc: addresses(10, "c"), bcc: addresses(11, "b"))) }
        .to raise_error(AhaSend::MessageError, %r{51 To/Cc/Bcc recipients; AhaSend accepts at most 50})
    end
  end

  describe "SMTP envelope override (smtp_envelope_to)" do
    it "delivers only to the envelope addresses, never to the header recipients" do
      mail = simple_mail(cc: "boss@example.com", bcc: "audit@example.com")
      mail.smtp_envelope_to = "test-inbox@example.com"

      built = build(mail)

      expect(built).not_to be_conversation
      expect(recipient_emails(built)).to eq(["test-inbox@example.com"])
      expect(built.payload).not_to include("to", "cc", "bcc")
    end

    it "accepts several envelope addresses, with or without display names" do
      mail = simple_mail
      mail.smtp_envelope_to = ["qa@example.com", "Dev <dev@example.com>"]

      expect(recipient_emails(build(mail))).to eq(%w[qa@example.com dev@example.com])
    end

    it "is not an override when it matches the header recipients" do
      mail = simple_mail(cc: "cc@example.com")
      mail.smtp_envelope_to = ["CC@example.com", "user@example.com"]

      expect(build(mail)).to be_conversation
    end

    it "rejects an explicitly empty envelope" do
      mail = simple_mail
      mail.smtp_envelope_to = []

      expect { build(mail) }.to raise_error(AhaSend::MessageError, /smtp_envelope_to/)
    end

    it "rejects an unparseable envelope address" do
      mail = simple_mail
      mail.smtp_envelope_to = "not an address <<"

      expect { build(mail) }.to raise_error(AhaSend::MessageError, /not a valid email address/)
    end
  end

  describe "substitutions" do
    it "are sent on /messages" do
      mail = simple_mail
      mail.ahasend.substitutions = { "name" => "Ann" }

      expect(build(mail).payload["substitutions"]).to eq("name" => "Ann")
    end

    it "work for Bcc-only mail, which goes through /messages" do
      mail = simple_mail(to: nil, bcc: "b@example.com")
      mail["AhaSend-Substitutions"] = '{"name":"Ann"}'

      expect(build(mail).payload["substitutions"]).to eq("name" => "Ann")
    end

    it "cannot be combined with Cc/Bcc: the conversation endpoint would send the template unrendered" do
      mail = simple_mail(cc: "archive@example.com")
      mail.ahasend.substitutions = { "name" => "Ann" }

      expect { build(mail) }.to raise_error(AhaSend::MessageError, %r{substitutions cannot be combined with Cc/Bcc})
    end

    it "from settings defaults are rejected with Cc/Bcc too" do
      expect { build(simple_mail(bcc: "a@example.com"), defaults: { substitutions: { company: "Acme" } }) }
        .to raise_error(AhaSend::MessageError, /substitutions/)
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

    # API contract: "The value must be wrapped in angle brackets ... If the
    # angle brackets are omitted, the file is delivered as a regular
    # (downloadable) attachment instead of rendering inline."
    it "sends an inline image's Content-ID wrapped in angle brackets, matching the cid: the HTML uses" do
      mail = simple_mail
      mail.attachments.inline["logo.png"] = "\x89PNG\r\nfake"
      att = build(mail).payload["attachments"].first

      expect(att["content_disposition"]).to eq("inline")
      expect(att["content_id"]).to match(/\A<[^<>]+>\z/)
      expect(att["content_id"]).to eq("<#{mail.attachments["logo.png"].url.delete_prefix("cid:")}>")
      expect(att["file_name"]).to eq("logo.png")
      expect(att["content_type"]).to eq("image/png")
    end

    it "sends the real Content-ID, not its URL-escaped cid: form" do
      mail = simple_mail
      mail.attachments.inline["logo.png"] = { content: "\x89PNG", content_id: "<lögo@example.com>" }

      expect(build(mail).payload["attachments"].first["content_id"]).to eq("<lögo@example.com>")
      expect(mail.attachments["logo.png"].url).to eq("cid:l%C3%B6go@example.com")
    end

    it "brackets a Content-ID that was supplied without brackets" do
      mail = simple_mail
      mail.attachments.inline["logo.png"] = { content: "\x89PNG", content_id: "logo@example.com" }

      expect(build(mail).payload["attachments"].first["content_id"]).to eq("<logo@example.com>")
    end

    # An idempotency key can only be reused for a byte-identical request. Mail
    # gives inline images a random Content-ID, so a rebuilt message (a job
    # retry) differs unless the Content-ID is supplied explicitly.
    it "produces identical payloads for rebuilt messages when the Content-ID is supplied" do
      build_inline = lambda do |content_id|
        mail = simple_mail(body: nil)
        mail.attachments.inline["logo.png"] = content_id ? { content: "\x89PNG", content_id: content_id } : "\x89PNG"
        url = mail.attachments["logo.png"].url
        mail.html_part = Mail::Part.new do
          content_type "text/html; charset=UTF-8"
          body %(<img src="#{url}">)
        end
        build(mail).payload
      end

      first_build, rebuild = Array.new(2) { build_inline.call("<logo@acme.test>") }
      expect(rebuild).to eq(first_build)

      first_build, rebuild = Array.new(2) { build_inline.call(nil) }
      expect(rebuild).not_to eq(first_build)
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

  describe "options" do
    it "maps every option onto its payload field" do
      mail = simple_mail
      mail["AhaSend-Tags"] = "welcome, onboarding ,"
      mail["AhaSend-Track-Opens"] = "true"
      mail["AhaSend-Track-Clicks"] = "no"
      mail["AhaSend-Metadata-Retention"] = "30"
      mail["AhaSend-Data-Retention"] = "0"
      mail["AhaSend-Schedule-First-Attempt"] = "2026-01-01T00:00:00Z"
      mail["AhaSend-Sandbox"] = "1"
      mail["AhaSend-Sandbox-Result"] = "bounce"
      mail["AhaSend-Idempotency-Key"] = "key-1"
      mail["AhaSend-Substitutions"] = '{"first_name":"Ann"}'

      built = build(mail)

      expect(built.payload).to include(
        "tags" => %w[welcome onboarding],
        "tracking" => { "open" => true, "click" => false },
        "retention" => { "metadata" => 30, "data" => 0 },
        "schedule" => { "first_attempt" => "2026-01-01T00:00:00Z" },
        "sandbox" => true,
        "sandbox_result" => "bounce",
        "substitutions" => { "first_name" => "Ann" }
      )
      expect(built.idempotency_key).to eq("key-1")
      expect(built.payload).not_to include("headers")
    end

    it "merges nested options field by field across settings, headers and Ruby" do
      mail = simple_mail
      mail["AhaSend-Metadata-Retention"] = "1"
      mail.ahasend.tracking = { "click" => true }

      payload = build(mail, defaults: { retention: { metadata: 30, data: 0 }, tracking: { open: false } }).payload

      expect(payload["retention"]).to eq("metadata" => 1, "data" => 0)
      expect(payload["tracking"]).to eq("open" => false, "click" => true)
    end

    it "omits option fields entirely when unset" do
      payload = build(simple_mail).payload
      expect(payload.keys).to contain_exactly("from", "recipients", "subject", "text_content")
    end

    it "rejects unknown settings keys instead of ignoring them" do
      expect { build(simple_mail, defaults: { sandbx: true }) }
        .to raise_error(AhaSend::ConfigurationError, /ahasend_settings\[:sandbx\]/)
    end
  end
end
