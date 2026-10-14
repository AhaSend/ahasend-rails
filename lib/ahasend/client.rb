# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "securerandom"

module AhaSend
  # Minimal HTTP client for the AhaSend v2 message endpoints.
  #
  # Every POST carries an Idempotency-Key (generated when the caller doesn't
  # supply one), which is what makes the automatic retries safe: a request
  # the API already completed is answered from its store instead of sending
  # the email a second time. Retried: 429, 5xx, network failures, and a 409
  # saying the same key is still in progress. The request (key and body) is
  # built once and reused for every attempt.
  class Client
    # A 2xx answer. `body` is the parsed JSON (or the raw String when the body
    # was not JSON); header names are lower case.
    Response = Struct.new(:status, :headers, :body) do
      # True when the API answered from its idempotency store: an identical
      # request with this key had already completed, and nothing was re-sent.
      def replayed? = headers["idempotent-replayed"] == "true"
    end

    SETTINGS = %i[api_key account_id base_url open_timeout read_timeout max_retries].freeze

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
      @api_key = required_string(api_key, :api_key)
      @account_id = required_string(account_id, :account_id)
      @base_url = (base_url.nil? ? DEFAULT_BASE_URL : base_url).to_s.chomp("/")
      @base_uri = parse_base_url(@base_url)
      @open_timeout = positive_seconds(open_timeout.nil? ? DEFAULT_OPEN_TIMEOUT : open_timeout, :open_timeout)
      @read_timeout = positive_seconds(read_timeout.nil? ? DEFAULT_READ_TIMEOUT : read_timeout, :read_timeout)
      @max_retries = retry_count(max_retries.nil? ? DEFAULT_MAX_RETRIES : max_retries)
    end

    # POST /v2/accounts/{account_id}/messages[/conversation]. Returns a
    # Response for any 2xx; raises an ApiError subclass otherwise.
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

        headers = response.each_header.to_h
        body = parse_body(response)
        return Response.new(response.code.to_i, headers, body) if response.is_a?(Net::HTTPSuccess)

        error = ApiError.for(status: response.code.to_i, headers: headers, body: body)
        raise error if last || !retryable?(error)

        wait(backoff(attempt, retry_after: error.retry_after))
      end
    end

    private

    def retryable?(error)
      RETRYABLE_STATUSES.include?(error.status) || (error.is_a?(IdempotencyError) && error.in_progress?)
    end

    def build_request(path, payload, idempotency_key)
      # Keep any path prefix on base_url (e.g. a proxy mounted under /ahasend).
      request = Net::HTTP::Post.new(@base_uri.path.chomp("/") + path)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["User-Agent"] = "ahasend-rails/#{VERSION} ruby/#{RUBY_VERSION}"
      request["Idempotency-Key"] = idempotency_key
      request.body = encode(payload)
      request
    end

    def encode(payload)
      JSON.generate(payload)
    rescue JSON::GeneratorError => e
      raise MessageError, "the message could not be encoded as JSON (#{e.message.lines.first.strip}); " \
                          "check that its text parts are valid UTF-8"
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
      return [retry_after, MAX_RETRY_AFTER].min if retry_after

      base = [0.5 * (2**attempt), MAX_BACKOFF].min
      base * (0.5 + (rand * 0.5))
    end

    def wait(seconds)
      sleep(seconds)
    end

    def parse_body(response)
      body = response.body
      return nil if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      body
    end

    def required_string(value, name)
      string = value.to_s
      return string unless string.strip.empty?

      raise ConfigurationError, "ahasend_settings[:#{name}] is required"
    end

    def positive_seconds(value, name)
      return value if value.is_a?(Numeric) && value.positive?

      raise ConfigurationError, "ahasend_settings[:#{name}] must be a positive number of seconds, got #{value.inspect}"
    end

    def retry_count(value)
      return value if value.is_a?(Integer) && !value.negative?

      raise ConfigurationError, "ahasend_settings[:max_retries] must be an Integer of 0 or more, got #{value.inspect}"
    end

    def parse_base_url(value)
      uri = URI.parse(value)
      return uri if uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?

      raise ConfigurationError, "ahasend_settings[:base_url] must be an http(s) URL with a host, got #{value.inspect}"
    rescue URI::InvalidURIError
      raise ConfigurationError, "ahasend_settings[:base_url] must be an http(s) URL with a host, got #{value.inspect}"
    end
  end
end
