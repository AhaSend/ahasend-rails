# frozen_string_literal: true

RSpec.describe AhaSend::Options do
  def mail_with_headers(headers)
    mail = Mail.new do
      from "sender@example.com"
      to "user@example.com"
    end
    headers.each { |name, value| mail[name] = value }
    mail
  end

  describe ".from_headers" do
    it "reads AhaSend's SMTP special headers under their SMTP names, case-insensitively" do
      options = described_class.from_headers(mail_with_headers(
                                               "ahasend-tags" => "a,b",
                                               "ahasend-track-opens" => "true",
                                               "ahasend-track-clicks" => "false",
                                               "AhaSend-Sandbox" => "1",
                                               "AhaSend-Sandbox-Result" => "defer",
                                               "ahasend-metadata-retention" => "7",
                                               "ahasend-data-retention" => "0"
                                             ))

      expect(options).to eq(
        tags: %w[a b], tracking: { "open" => true, "click" => false }, sandbox: true,
        sandbox_result: "defer", retention: { "metadata" => 7, "data" => 0 }
      )
    end

    it "reads the API-only headers" do
      options = described_class.from_headers(mail_with_headers(
                                               "AhaSend-Substitutions" => '{"name":"Ann","n":1}',
                                               "AhaSend-Schedule-First-Attempt" => "2026-01-01T00:00:00Z",
                                               "AhaSend-Schedule-Expires" => "2026-01-02T00:00:00Z",
                                               "AhaSend-Idempotency-Key" => "order-1"
                                             ))

      expect(options).to eq(
        substitutions: { "name" => "Ann", "n" => 1 },
        schedule: { "first_attempt" => "2026-01-01T00:00:00Z", "expires" => "2026-01-02T00:00:00Z" },
        idempotency_key: "order-1"
      )
    end

    it "ignores empty values and non-AhaSend headers" do
      expect(described_class.from_headers(mail_with_headers("AhaSend-Tags" => " ", "X-Other" => "1"))).to eq({})
    end

    {
      "AhaSend-Sandbox" => ["tru", /AhaSend-Sandbox must be true or false, got "tru"/],
      "AhaSend-Track-Opens" => ["enabled", /AhaSend-Track-Opens must be true or false/],
      "AhaSend-Data-Retention" => ["abc", /AhaSend-Data-Retention must be a whole number of days, got "abc"/],
      "AhaSend-Metadata-Retention" => ["1.5", /AhaSend-Metadata-Retention must be a whole number/],
      "AhaSend-Substitutions" => ["{not json", /AhaSend-Substitutions is not valid JSON/],
      "AhaSend-Sandbox-Result" => ["bounced", /AhaSend-Sandbox-Result must be one of deliver, bounce/],
      "AhaSend-Idempotency-Key" => ["x" * 256, /AhaSend-Idempotency-Key must be a non-empty String of at most 255/]
    }.each do |header, (value, message)|
      it "rejects #{header}: #{value[0, 20].inspect} with a MessageError naming the header" do
        expect { described_class.from_headers(mail_with_headers(header => value)) }
          .to raise_error(AhaSend::MessageError, message)
      end
    end

    it "rejects a JSON substitutions value that is not an object" do
      expect { described_class.from_headers(mail_with_headers("AhaSend-Substitutions" => "[1,2]")) }
        .to raise_error(AhaSend::MessageError, /must be a JSON object/)
    end

    it "rejects an unknown AhaSend-* header so a typo cannot silently drop an option" do
      expect { described_class.from_headers(mail_with_headers("AhaSend-Sanbox" => "true")) }
        .to raise_error(AhaSend::MessageError, /unknown header AhaSend-Sanbox; supported AhaSend headers are .*AhaSend-Sandbox/)
    end

    it "lets the last of a repeated header win" do
      mail = mail_with_headers("AhaSend-Tags" => "first")
      mail["AhaSend-Tags"] = "second"

      expect(described_class.from_headers(mail)).to eq(tags: ["second"])
    end
  end

  describe ".from_message_options" do
    it "normalises symbol and string keys in nested options" do
      options = described_class.from_message_options(
        AhaSend::MessageOptions.new(tracking: { open: true }, retention: { "data" => 1 }, substitutions: { name: "Ann" })
      )

      expect(options).to eq(tracking: { "open" => true }, retention: { "data" => 1 }, substitutions: { "name" => "Ann" })
    end

    it "converts Time values in schedule to RFC 3339" do
      time = Time.utc(2026, 1, 1, 9, 30)
      options = described_class.from_message_options(AhaSend::MessageOptions.new(schedule: { first_attempt: time }))

      expect(options).to eq(schedule: { "first_attempt" => "2026-01-01T09:30:00Z" })
    end

    {
      tracking: [true, /message.ahasend.tracking must be a Hash/],
      retention: [{ data: "7" }, /message.ahasend.retention\[:data\] must be a whole number of days/],
      schedule: [{ first: "x" }, /message.ahasend.schedule has unknown key\(s\) first; expected first_attempt, expires/],
      tags: ["welcome", /message.ahasend.tags must be an Array of non-empty Strings/],
      sandbox: ["maybe", /message.ahasend.sandbox must be true or false/],
      sandbox_result: [:bounce, /message.ahasend.sandbox_result must be one of/]
    }.each do |name, (value, message)|
      it "rejects #{name}: #{value.inspect}" do
        expect { described_class.from_message_options(AhaSend::MessageOptions.new(name => value)) }
          .to raise_error(AhaSend::MessageError, message)
      end
    end
  end

  describe ".from_settings" do
    it "validates like Ruby options but raises ConfigurationError" do
      expect { described_class.from_settings(tracking: { opens: true }) }
        .to raise_error(AhaSend::ConfigurationError, /ahasend_settings\[:tracking\] has unknown key\(s\) opens/)
    end

    it "rejects unknown keys" do
      expect { described_class.from_settings(sandbx: true) }
        .to raise_error(AhaSend::ConfigurationError, /ahasend_settings\[:sandbx\] is not a supported AhaSend option/)
    end

    it "rejects an idempotency key, which must be unique per message" do
      expect { described_class.from_settings(idempotency_key: "shared") }
        .to raise_error(AhaSend::ConfigurationError, /idempotency_key\] is not allowed/)
    end

    it "accepts boolean strings, e.g. from ENV" do
      expect(described_class.from_settings(sandbox: "true")).to eq(sandbox: true)
    end
  end

  describe ".merge" do
    it "merges nested hashes per field and replaces everything else" do
      merged = described_class.merge(
        { retention: { "metadata" => 30, "data" => 0 }, tags: ["a"], sandbox: true },
        { retention: { "metadata" => 1 }, tags: ["b"] },
        { sandbox: false }
      )

      expect(merged).to eq(retention: { "metadata" => 1, "data" => 0 }, tags: ["b"], sandbox: false)
    end
  end
end
