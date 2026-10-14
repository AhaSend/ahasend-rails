# frozen_string_literal: true

RSpec.describe AhaSend::Client do
  subject(:client) { described_class.new(**settings) }

  let(:payload) { { "from" => { "email" => "a@example.com" }, "subject" => "hi" } }

  before { allow(client).to receive(:wait) } # never actually sleep in tests

  describe "#initialize" do
    it "requires an api_key" do
      expect { described_class.new(api_key: " ", account_id: "x") }
        .to raise_error(AhaSend::ConfigurationError, /api_key/)
    end

    it "requires an account_id" do
      expect { described_class.new(api_key: "k", account_id: nil) }
        .to raise_error(AhaSend::ConfigurationError, /account_id/)
    end

    it "applies defaults" do
      expect(client.base_url).to eq("https://api.ahasend.com")
      expect(client.max_retries).to eq(2)
      expect(client.open_timeout).to eq(10)
      expect(client.read_timeout).to eq(30)
    end

    it "strips a trailing slash from base_url" do
      expect(described_class.new(**settings(base_url: "https://eu.example.com/")).base_url)
        .to eq("https://eu.example.com")
    end

    {
      max_retries: [-1, 1.5, "2", ""],
      open_timeout: [0, -5, "10"],
      read_timeout: [0, -1, "30"],
      base_url: ["ftp://example.com", "api.ahasend.com", "https://", "http://exa mple.com"]
    }.each do |key, values|
      values.each do |value|
        it "rejects #{key}: #{value.inspect}" do
          expect { described_class.new(**settings(key => value)) }
            .to raise_error(AhaSend::ConfigurationError, /ahasend_settings\[:#{key}\]/)
        end
      end
    end

    it "accepts max_retries: 0 and fractional timeouts" do
      expect(described_class.new(**settings(max_retries: 0, open_timeout: 0.5)).max_retries).to eq(0)
    end
  end

  describe "#send_message" do
    it "POSTs JSON to /messages with auth, accept and user-agent headers" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(api_fixture("create_message_202"))

      response = client.send_message(payload)

      expect(stub.with do |req|
        req.headers["Authorization"] == "Bearer #{ApiHelpers::API_KEY}" &&
          req.headers["Content-Type"] == "application/json" &&
          req.headers["Accept"] == "application/json" &&
          req.headers["User-Agent"].start_with?("ahasend-rails/#{AhaSend::VERSION}") &&
          request_json(req) == payload
      end).to have_been_requested.once
      expect(response.status).to eq(202)
      expect(response.body.dig("data", 0, "status")).to eq("queued")
      expect(response).not_to be_replayed
    end

    it "reports a replayed response" do
      stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(api_fixture("replayed_202"))
      expect(client.send_message(payload)).to be_replayed
    end

    it "targets /messages/conversation when conversation: true" do
      stub = stub_request(:post, ApiHelpers::CONVERSATION_URL).to_return(queued_response)
      client.send_message(payload, conversation: true)
      expect(stub).to have_been_requested
    end

    it "generates a UUID Idempotency-Key when none is given" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(queued_response)
      client.send_message(payload)
      expect(stub.with { |r| r.headers["Idempotency-Key"].match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/) })
        .to have_been_requested
    end

    it "uses the caller's Idempotency-Key" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL)
             .with(headers: { "Idempotency-Key" => "order-42" }).to_return(queued_response)
      client.send_message(payload, idempotency_key: "order-42")
      expect(stub).to have_been_requested
    end

    it "honours a custom base_url, including a path prefix" do
      custom = described_class.new(**settings(base_url: "http://localhost:4010/proxy/"))
      stub = stub_request(:post, "http://localhost:4010/proxy/v2/accounts/#{ApiHelpers::ACCOUNT_ID}/messages")
             .to_return(queued_response)
      custom.send_message(payload)
      expect(stub).to have_been_requested
    end

    it "raises MessageError, not a JSON error, when the payload is not valid UTF-8" do
      bad = { "text_content" => (+"caf\xE9").force_encoding("UTF-8") }
      expect { client.send_message(bad) }.to raise_error(AhaSend::MessageError, /UTF-8/)
    end
  end

  describe "error mapping (send endpoints, AhaSend API v2)" do
    {
      400 => AhaSend::ValidationError,
      401 => AhaSend::AuthenticationError,
      403 => AhaSend::ForbiddenError,
      404 => AhaSend::NotFoundError,
      409 => AhaSend::ApiError, # a 409 without the in-progress header pair
      412 => AhaSend::ApiError, # v2 has no 412 tombstone
      418 => AhaSend::ApiError
    }.each do |status, klass|
      it "raises #{klass} for HTTP #{status} without retrying" do
        stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(error_response(status, "nope"))

        expect { client.send_message(payload) }.to raise_error(klass) { |e|
          expect(e).to be_instance_of(klass)
          expect(e.status).to eq(status)
          expect(e.body).to eq("message" => "nope")
          expect(e.message).to eq("AhaSend API error #{status}: nope")
        }
        expect(stub).to have_been_requested.once
      end
    end

    it "raises ForbiddenError for a paused sending domain" do
      stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(api_fixture("domain_paused_403"))
      expect { client.send_message(payload) }.to raise_error(AhaSend::ForbiddenError, /is paused/)
    end

    it "raises IdempotencyError for a payload mismatch (422 carries no idempotency headers)" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(api_fixture("idempotency_payload_mismatch_422"))

      expect { client.send_message(payload) }.to raise_error(AhaSend::IdempotencyError) { |e|
        expect(e).not_to be_in_progress
        expect(e.retry_after).to be_nil
      }
      expect(stub).to have_been_requested.once
    end

    it "keeps a non-JSON body as a string" do
      stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(status: 400, body: "<html>bad</html>")
      expect { client.send_message(payload) }.to raise_error(AhaSend::ValidationError) { |e|
        expect(e.body).to eq("<html>bad</html>")
        expect(e.message).to include("<html>bad</html>")
      }
    end
  end

  describe "retries" do
    it "retries an in-progress 409 after Retry-After, with the same key and body" do
      seen = []
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL)
             .with { |r| seen << [r.headers["Idempotency-Key"], r.body] }
             .to_return(api_fixture("idempotency_in_progress_409"), api_fixture("create_message_202"))

      client.send_message(payload, idempotency_key: "order-42")

      expect(stub).to have_been_requested.twice
      expect(seen.uniq).to eq([["order-42", JSON.generate(payload)]])
      expect(client).to have_received(:wait).with(2.0).once
    end

    it "raises an in-progress IdempotencyError once retries are exhausted" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(api_fixture("idempotency_in_progress_409"))

      expect { client.send_message(payload) }.to raise_error(AhaSend::IdempotencyError) { |e|
        expect(e).to be_in_progress
        expect(e.retry_after).to eq(2.0)
      }
      expect(stub).to have_been_requested.times(3)
    end

    it "does not retry a 409 whose Retry-After is not a positive integer" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL)
             .to_return(error_response(409, "busy", headers: { "Idempotent-Replayed" => "false", "Retry-After" => "0" }))

      expect { client.send_message(payload) }.to raise_error(AhaSend::ApiError)
      expect(stub).to have_been_requested.once
    end

    it "retries 429 and then succeeds, honouring Retry-After" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL)
             .to_return(error_response(429, "slow down", headers: { "Retry-After" => "3" }), queued_response)

      client.send_message(payload)

      expect(stub).to have_been_requested.twice
      expect(client).to have_received(:wait).with(3.0).once
    end

    [500, 502, 503, 504].each do |status|
      it "retries #{status} with exponential backoff" do
        stub = stub_request(:post, ApiHelpers::MESSAGES_URL)
               .to_return(error_response(status), error_response(status), queued_response)

        client.send_message(payload)

        expect(stub).to have_been_requested.times(3)
        expect(client).to have_received(:wait).twice do |seconds|
          expect(seconds).to be_between(0.25, 8.0)
        end
      end
    end

    it "gives up after max_retries and raises the last error" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(error_response(503, "down"))

      expect { client.send_message(payload) }.to raise_error(AhaSend::ServerError, /503: down/)
      expect(stub).to have_been_requested.times(3)
    end

    it "caps an excessive Retry-After" do
      stub_request(:post, ApiHelpers::MESSAGES_URL)
        .to_return(error_response(429, "slow", headers: { "Retry-After" => "3600" }), queued_response)

      client.send_message(payload)

      expect(client).to have_received(:wait).with(30.0).once
    end

    it "retries a malformed HTTP response" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL)
             .to_raise(Net::HTTPBadResponse).then.to_return(queued_response)

      client.send_message(payload)
      expect(stub).to have_been_requested.twice
    end

    it "surfaces RateLimitError#retry_after when retries are exhausted" do
      stub_request(:post, ApiHelpers::MESSAGES_URL)
        .to_return(error_response(429, "limit", headers: { "Retry-After" => "7" }))

      expect { client.send_message(payload) }.to raise_error(AhaSend::RateLimitError) { |e|
        expect(e.retry_after).to eq(7.0)
      }
    end

    it "retries network failures and wraps the final one in ConnectionError" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_timeout

      expect { client.send_message(payload) }.to raise_error(AhaSend::ConnectionError, /Timeout/)
      expect(stub).to have_been_requested.times(3)
    end

    it "recovers from a transient connection reset" do
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL)
             .to_raise(Errno::ECONNRESET).then.to_return(queued_response)

      expect(client.send_message(payload).body).to include("object" => "list")
      expect(stub).to have_been_requested.twice
    end

    it "reuses the same Idempotency-Key across retries" do
      keys = []
      stub_request(:post, ApiHelpers::MESSAGES_URL).with { |r| keys << r.headers["Idempotency-Key"] }
                                                   .to_return(error_response(503), queued_response)

      client.send_message(payload)

      expect(keys.size).to eq(2)
      expect(keys.uniq.size).to eq(1)
    end

    it "does not retry when max_retries is 0" do
      none = described_class.new(**settings(max_retries: 0))
      stub = stub_request(:post, ApiHelpers::MESSAGES_URL).to_return(error_response(503))

      expect { none.send_message(payload) }.to raise_error(AhaSend::ServerError)
      expect(stub).to have_been_requested.once
    end
  end
end
