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

    # `id` is AhaSend's ID for the message, which Get Message and Cancel
    # Message take; `message_id_header` is the Message-ID header of the email
    # sent. Both are nil for a rejected recipient.
    Message = Struct.new(:id, :message_id_header, :status, :recipient, :error, :schedule, keyword_init: true) do
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

    # The first message's ID and Message-ID header (nil when that recipient
    # was rejected).
    def id = messages.first.id
    def message_id_header = messages.first.message_id_header
    def status = messages.first.status
    def failed = messages.select(&:error?)
    def accepted = messages.reject(&:error?)
    def success? = failed.empty?

    # Some recipients were accepted and others rejected. The accepted ones
    # are being sent, so this is not raised as an error (a retried job would
    # send them a second copy); the rejections are in #failed and in the
    # deliver.ahasend notification.
    def partial? = failed.any? && accepted.any?

    # True when the API answered from its idempotency store: this exact
    # request (same Idempotency-Key) had already been processed, and these
    # are the original results.
    def replayed? = @replayed

    # Instrumentation payload: provider IDs and per-recipient statuses only,
    # never message content.
    def to_notification
      {
        message_ids: messages.map(&:id).compact,
        recipients: messages.map do |m|
          { email: m.recipient, status: m.status, id: m.id, message_id_header: m.message_id_header, error: m.error }
        end,
        failed_recipients: failed.map(&:recipient),
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

      header = header_of(entry)
      return unless header.nil? || header.is_a?(String)

      Message.new(id: entry["id"], message_id_header: header, status: entry["status"], recipient: recipient["email"],
                  error: entry["error"], schedule: entry["schedule"])
    end

    # The older response form has no `message_id_header` and gives the
    # Message-ID header as `id`. A request repeated with an earlier
    # Idempotency-Key can still return it for 24 hours after the API change.
    def header_of(entry)
      entry.fetch("message_id_header") { entry["id"] }
    end

    def valid_id?(entry)
      id = entry["id"]
      (id.is_a?(String) && !id.empty?) || (id.nil? && entry["status"] == "error")
    end
  end
end
