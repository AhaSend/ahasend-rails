# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "securerandom"

module AhaSend
  # Minimal HTTP client for the AhaSend v2 message endpoints.
  #
  # Every POST carries an Idempotency-Key (generated when the caller doesn't
  # supply one), which is what makes the automatic retries on 429 / 5xx /
  # network failures safe: a request the API already processed is replayed
  # from its cache instead of sending the email a second time.
  class Client
    DEFAULT_BASE_URL = "https://api.ahasend.com"
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 30
    DEFAULT_MAX_RETRIES = 2
    MAX_BACKOFF = 8.0
    # Longest Retry-After we are willing to sleep inside a caller's job/thread.
    MAX_RETRY_AFTER = 30.0

    RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze
    NETWORK_ERRORS = [
      Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ECONNABORTED, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EPIPE, EOFError, SocketError, IOError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    ].freeze

    attr_reader :account_id, :base_url, :open_timeout, :read_timeout, :max_retries

    def initialize(api_key: nil, account_id: nil, base_url: nil, open_timeout: nil, read_timeout: nil,
                   max_retries: nil)
      @api_key = api_key.to_s
      @account_id = account_id.to_s
      raise ConfigurationError, "ahasend_settings[:api_key] is required" if @api_key.empty?
      raise ConfigurationError, "ahasend_settings[:account_id] is required" if @account_id.empty?

      @base_url = (base_url || DEFAULT_BASE_URL).to_s.chomp("/")
      @base_uri = URI.parse(@base_url)
      @open_timeout = open_timeout || DEFAULT_OPEN_TIMEOUT
      @read_timeout = read_timeout || DEFAULT_READ_TIMEOUT
      @max_retries = max_retries || DEFAULT_MAX_RETRIES
    end

    # POST /v2/accounts/{account_id}/messages[/conversation]. Returns the
    # parsed JSON response body.
    def send_message(payload, conversation: false, idempotency_key: nil)
      path = "/v2/accounts/#{account_id}/messages#{"/conversation" if conversation}"
      post(path, payload, idempotency_key: idempotency_key)
    end

    def post(path, payload, idempotency_key: nil)
      request = build_request(path, payload, idempotency_key || SecureRandom.uuid)

      (max_retries + 1).times do |attempt|
        last = attempt == max_retries
        begin
          response = perform(request)
        rescue *NETWORK_ERRORS => e
          raise ConnectionError, "#{e.class}: #{e.message}" if last

          wait(backoff(attempt))
          next
        end

        return parse_body(response) if response.is_a?(Net::HTTPSuccess)

        error = ApiError.for(status: response.code.to_i, headers: response_headers(response), body: parse_body(response))
        raise error if last || !RETRYABLE_STATUSES.include?(error.status)

        wait(backoff(attempt, retry_after: response["retry-after"]))
      end
    end

    private

    def build_request(path, payload, idempotency_key)
      # Keep any path prefix on base_url (e.g. a proxy mounted under /ahasend).
      request = Net::HTTP::Post.new(@base_uri.path.chomp("/") + path)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["User-Agent"] = "ahasend-rails/#{VERSION} ruby/#{RUBY_VERSION}"
      request["Idempotency-Key"] = idempotency_key
      request.body = JSON.generate(payload)
      request
    end

    def perform(request)
      http = Net::HTTP.new(@base_uri.host, @base_uri.port)
      http.use_ssl = @base_uri.scheme == "https"
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout
      http.request(request)
    end

    # Retry-After wins when the API sent one; otherwise exponential backoff
    # with jitter, capped so a long outage fails fast rather than hanging.
    def backoff(attempt, retry_after: nil)
      return [Float(retry_after), MAX_RETRY_AFTER].min if retry_after&.match?(/\A\d+(\.\d+)?\z/)

      base = [0.5 * (2**attempt), MAX_BACKOFF].min
      base * (0.5 + (rand * 0.5))
    end

    def wait(seconds)
      sleep(seconds)
    end

    def response_headers(response)
      response.each_header.to_h
    end

    def parse_body(response)
      body = response.body
      return nil if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      body
    end
  end
end
