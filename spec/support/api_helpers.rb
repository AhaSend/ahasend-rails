# frozen_string_literal: true

module ApiHelpers
  ACCOUNT_ID = "acc-123"
  API_KEY = "aha-sk-test"
  MESSAGES_URL = "https://api.ahasend.com/v2/accounts/#{ACCOUNT_ID}/messages".freeze
  CONVERSATION_URL = "#{MESSAGES_URL}/conversation".freeze
  FIXTURES = File.expand_path("../fixtures/api", __dir__)

  def settings(**extra)
    { api_key: API_KEY, account_id: ACCOUNT_ID }.merge(extra)
  end

  # A WebMock response built from a fixture in spec/fixtures/api, which
  # mirrors the AhaSend OpenAPI spec (see the README there).
  def api_fixture(name)
    fixture = JSON.parse(File.read(File.join(FIXTURES, "#{name}.json")))
    { status: fixture.fetch("status"), headers: fixture.fetch("headers"), body: JSON.generate(fixture.fetch("body")) }
  end

  def request_contract
    @request_contract ||= JSON.parse(File.read(File.join(FIXTURES, "request_contract.json")))
  end

  # A valid send response with one queued entry per recipient.
  def queued_response(*emails, status: "queued")
    emails = ["user@example.com"] if emails.empty?
    data = emails.map do |email|
      { "object" => "message", "id" => "<#{email.tr("@", "-")}@ahasend.com>", "status" => status,
        "recipient" => { "email" => email, "name" => "" }, "error" => nil }
    end
    { status: 202, body: JSON.generate("object" => "list", "data" => data),
      headers: { "Content-Type" => "application/json" } }
  end

  def error_response(status, message = "boom", headers: {})
    { status: status, body: JSON.generate("message" => message),
      headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  def request_json(request)
    JSON.parse(request.body)
  end
end

RSpec.configure { |c| c.include ApiHelpers }
