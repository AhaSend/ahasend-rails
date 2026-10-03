# frozen_string_literal: true

module AhaSend
  # Base class for every error raised by this gem.
  class Error < StandardError; end

  # Missing or invalid delivery-method settings (no api_key, no account_id, ...).
  class ConfigurationError < Error; end

  # The request never produced an HTTP response (DNS, TCP, TLS, timeout).
  # The underlying exception is available via `cause`.
  class ConnectionError < Error; end

  # A non-2xx HTTP response from the API. Instances carry the raw status,
  # headers and (parsed, when JSON) body so callers can inspect them.
  class ApiError < Error
    attr_reader :status, :headers, :body

    def initialize(message = nil, status:, headers: {}, body: nil)
      @status = status
      @headers = headers
      @body = body
      super(message || default_message)
    end

    # Picks the most specific subclass for an HTTP status.
    def self.for(status:, headers: {}, body: nil)
      klass =
        case status
        when 400, 422 then ValidationError
        when 401, 403 then AuthenticationError
        when 404 then NotFoundError
        when 409 then IdempotencyError
        when 429 then RateLimitError
        when 500..599 then ServerError
        else ApiError
        end
      klass.new(status: status, headers: headers, body: body)
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
  class NotFoundError < ApiError; end
  class IdempotencyError < ApiError; end
  class ServerError < ApiError; end

  class RateLimitError < ApiError
    # Seconds the API asked us to wait, if it sent a Retry-After header.
    def retry_after
      value = headers["retry-after"]
      Float(value) if value&.match?(/\A\d+(\.\d+)?\z/)
    end
  end

  # The API accepted the request (202) but reported `status: "error"` for one
  # or more recipients. `result` holds the full per-recipient breakdown; any
  # recipient that was queued has still been sent.
  class DeliveryError < Error
    attr_reader :result

    def initialize(result)
      @result = result
      failed = result.failed.map { |m| "#{m.recipient}: #{m.error || "unknown error"}" }
      super("AhaSend rejected #{failed.size} of #{result.messages.size} recipient(s): #{failed.join("; ")}")
    end
  end
end
