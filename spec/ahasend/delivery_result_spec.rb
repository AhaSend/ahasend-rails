# frozen_string_literal: true

RSpec.describe AhaSend::DeliveryResult do
  def entry(**overrides)
    { "object" => "message", "id" => "<a@ahasend.com>", "status" => "queued",
      "recipient" => { "email" => "a@example.com", "name" => "" }, "error" => nil }.merge(overrides.transform_keys(&:to_s))
  end

  def fixture_body(name)
    JSON.parse(File.read(File.join(ApiHelpers::FIXTURES, "#{name}.json"))).fetch("body")
  end

  it "parses the documented response" do
    result = described_class.new(fixture_body("create_message_202"))

    expect(result).to be_success
    expect(result.id).to eq("<9a3c5e1e-6f0b-4b9e-9a51-2c7f0e7d1a10@example.com>")
    expect(result.status).to eq("queued")
    expect(result.messages.map(&:recipient)).to eq(["user@example.com"])
  end

  it "accepts an error entry without an ID and reports a partial delivery" do
    result = described_class.new(fixture_body("create_message_partial_error_202"))

    expect(result).not_to be_success
    expect(result).to be_partial
    expect(result.accepted.map(&:recipient)).to eq(["ok@example.com"])
    expect(result.failed.map(&:recipient)).to eq(["user@blocked.example"])
    expect(result.failed.first.id).to be_nil
    expect(result.to_notification[:failed_recipients]).to eq(["user@blocked.example"])
  end

  it "is not partial when every recipient was rejected" do
    result = described_class.new({ "data" => [entry(id: nil, status: "error", error: "553 blocked")] })

    expect(result).not_to be_partial
    expect(result.accepted).to be_empty
  end

  it "accepts scheduled entries" do
    result = described_class.new({ "data" => [entry(status: "scheduled", schedule: { "first_attempt" => "x" })] })
    expect(result.status).to eq("scheduled")
  end

  it "exposes a notification payload without message content" do
    result = described_class.new({ "data" => [entry] }, replayed: true)

    expect(result.to_notification).to eq(
      message_ids: ["<a@ahasend.com>"],
      recipients: [{ email: "a@example.com", status: "queued", id: "<a@ahasend.com>", error: nil }],
      failed_recipients: [],
      replayed: true
    )
  end

  {
    "nil body" => nil,
    "non-JSON body" => "<html>ok</html>",
    "no data" => { "object" => "list" },
    "empty data" => { "data" => [] },
    "data not a list" => { "data" => "x" },
    "entry not an object" => { "data" => [1] },
    "empty entry" => { "data" => [{}] },
    "unknown status" => { "data" => [{ "id" => "<a@b>", "status" => "sent", "recipient" => { "email" => "a@b.c" } }] },
    "recipient not an object" => { "data" => [{ "id" => "<a@b>", "status" => "queued", "recipient" => "a@b.c" }] },
    "recipient without email" => { "data" => [{ "id" => "<a@b>", "status" => "queued", "recipient" => {} }] },
    "queued without an ID" => { "data" => [{ "id" => nil, "status" => "queued", "recipient" => { "email" => "a@b.c" } }] },
    "error that is not a string" => { "data" => [{ "id" => nil, "status" => "error", "recipient" => { "email" => "a@b.c" },
                                                   "error" => { "code" => 1 } }] },
    "one bad entry among good ones" => {
      "data" => [{ "id" => "<a@b>", "status" => "queued", "recipient" => { "email" => "a@b.c" } }, {}]
    }
  }.each do |description, body|
    it "raises UnexpectedResponseError (delivery state unknown) for #{description}" do
      expect { described_class.new(body) }
        .to raise_error(AhaSend::UnexpectedResponseError, /delivery state unknown/) { |e| expect(e.body).to eq(body) }
    end
  end
end
