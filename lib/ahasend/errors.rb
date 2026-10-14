# frozen_string_literal: true

module AhaSend
  # Base class for every error raised by this gem.
  class Error < StandardError; end

  # Invalid delivery-method settings: missing credentials, a negative retry
  # count, a base_url that is not http(s), an unknown settings key, ...
  # Checked the first time the delivery method sends, never at boot, so apps
  # using the :test delivery method need no AhaSend credentials.
  class ConfigurationError < Error; end

  # The message cannot be sent as built. Detected before any request is made:
  # a malformed or unknown AhaSend-* header or option, or a combination the
  # API cannot represent (substitutions with Cc/Bcc, Cc without To, no
  # recipients, no From).
  class MessageError < Error; end

  # The request never produced an HTTP response (DNS, TCP, TLS, timeout).
  # The underlying exception is available via `cause`.
  class ConnectionError < Error; end

  # A non-2xx HTTP response from the API. Instances carry the raw status,
  # headers (lower-case names) and body (parsed when JSON).
  class ApiError < Error
    attr_reader :status, :headers, :body

    def initialize(message = nil, status:, headers: {}, body: nil)
      @status = status
      @headers = headers
      @body = body
      super(message || default_message)
    end

    # Picks the most specific subclass for an HTTP status, following the
    # send endpoints' contract (AhaSend API v2):
    #   400 invalid request, 401 bad API key, 403 not allowed to send (key
    #   scope, account, or a paused sending domain), 409 with
    #   `Idempotent-Replayed: false` and a positive `Retry-After` = a request
    #   with the same Idempotency-Key is still running, 422 = the
    #   Idempotency-Key was already used for a different request.
    def self.for(status:, headers: {}, body: nil)
      klass =
        case status
        when 400 then ValidationError
        when 401 then AuthenticationError
        when 403 then ForbiddenError
        when 404 then NotFoundError
        when 409 then idempotency_in_progress?(headers) ? IdempotencyError : ApiError
        when 422 then IdempotencyError
        when 429 then RateLimitError
        when 500..599 then ServerError
        else ApiError
        end
      klass.new(status: status, headers: headers, body: body)
    end

    # The API marks an in-progress idempotent request only by this header
    # pair; the message text is not a stable discriminator.
    def self.idempotency_in_progress?(headers)
      headers["idempotent-replayed"] == "false" && headers["retry-after"].to_s.match?(/\A[1-9]\d*\z/)
    end

    # Seconds the API asked us to wait before retrying (Retry-After), if any.
    def retry_after
      value = headers["retry-after"]
      Float(value) if value&.match?(/\A\d+(\.\d+)?\z/)
    end

    # True when this response is a stored replay of an earlier request with
    # the same Idempotency-Key.
    def replayed?
      headers["idempotent-replayed"] == "true"
    end

    # Message returned by the API, when its JSON body carries one.
    def api_message
      body["message"] if body.is_a?(Hash)
    end

    private

    def default_message
      text = api_message || (body.is_a?(String) && !body.empty? ? body : nil)
      text ? "AhaSend API error #{status}: #{text}" : "AhaSend API error #{status}"
    end
  end

  class ValidationError < ApiError; end
  class AuthenticationError < ApiError; end
  class ForbiddenError < ApiError; end
  class NotFoundError < ApiError; end
  class RateLimitError < ApiError; end
  class ServerError < ApiError; end

  # A problem with the request's Idempotency-Key: the same key is still in
  # progress (409, retried automatically within max_retries), or it was
  # already used for a different request (422, never retried: a rebuilt
  # message must be byte-for-byte identical to reuse its key).
  class IdempotencyError < ApiError
    # True when the original request with this key is still running; retry
    # later (see #retry_after) with the same key and the same message.
    def in_progress?
      status == 409
    end
  end

  # A 2xx response whose body is not the documented message list, so there is
  # no Message-ID or per-recipient status to report. Nothing is assumed about
  # whether the email went out; check the AhaSend dashboard or logs.
  class UnexpectedResponseError < Error
    attr_reader :body

    def initialize(body)
      @body = body
      super("AhaSend returned a success status without a valid message list; delivery state unknown: " \
            "#{body.inspect[0, 200]}")
    end
  end

  # The API accepted the request (202) but rejected every recipient
  # (`status: "error"` for each). Nothing was sent, so retrying cannot
  # duplicate anything; a permanent rejection (such as a blocked recipient
  # domain) will fail again, though. `result` holds the per-recipient errors.
  # When only some recipients are rejected, nothing is raised: see
  # DeliveryResult#partial?.
  class DeliveryError < Error
    attr_reader :result

    def initialize(result)
      @result = result
      failed = result.failed.map { |m| "#{m.recipient}: #{m.error || "unknown error"}" }
      super("AhaSend rejected #{failed.size} of #{result.messages.size} recipient(s): #{failed.join("; ")}")
    end
  end
end
