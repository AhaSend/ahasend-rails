# frozen_string_literal: true

module AhaSend
  # The API's answer to a send: one entry per recipient. `id` and `status`
  # expose the first entry for convenience; `messages` has them all.
  #
  # The body is validated against the documented response shape before
  # anything is reported as delivered. A 2xx with any other shape raises
  # UnexpectedResponseError: the email may or may not have gone out.
  class DeliveryResult
    STATUSES = %w[queued scheduled error].freeze

    Message = Struct.new(:id, :status, :recipient, :error, :schedule, keyword_init: true) do
      def error? = status == "error"
    end

    attr_reader :raw, :messages

    def self.from_response(response)
      new(response.body, replayed: response.replayed?)
    end

    def initialize(raw, replayed: false)
      @raw = raw
      @replayed = replayed
      @messages = parse_messages(raw)
    end

    # RFC 822 Message-ID of the first message, e.g. "<uuid@example.com>"
    # (nil when that recipient was rejected).
    def id = messages.first.id
    def status = messages.first.status
    def failed = messages.select(&:error?)
    def success? = failed.empty?

    # True when the API answered from its idempotency store: this exact
    # request (same Idempotency-Key) had already been processed, and these
    # are the original results.
    def replayed? = @replayed

    # Instrumentation payload: provider IDs and per-recipient statuses only,
    # never message content.
    def to_notification
      {
        message_ids: messages.map(&:id).compact,
        recipients: messages.map { |m| { email: m.recipient, status: m.status, id: m.id, error: m.error } },
        replayed: replayed?
      }
    end

    private

    def parse_messages(raw)
      data = raw["data"] if raw.is_a?(Hash)
      raise UnexpectedResponseError, raw unless data.is_a?(Array) && !data.empty?

      data.map { |entry| parse_message(entry) || raise(UnexpectedResponseError, raw) }
    end

    # Per CreateSingleMessageResponse: a known status, a recipient object
    # with an email, and an ID unless the recipient was rejected (an error
    # entry may have none).
    def parse_message(entry)
      return unless entry.is_a?(Hash) && STATUSES.include?(entry["status"])

      recipient = entry["recipient"]
      return unless recipient.is_a?(Hash) && recipient["email"].is_a?(String)
      return unless valid_id?(entry) && (entry["error"].nil? || entry["error"].is_a?(String))

      Message.new(id: entry["id"], status: entry["status"], recipient: recipient["email"], error: entry["error"],
                  schedule: entry["schedule"])
    end

    def valid_id?(entry)
      id = entry["id"]
      (id.is_a?(String) && !id.empty?) || (id.nil? && entry["status"] == "error")
    end
  end
end
