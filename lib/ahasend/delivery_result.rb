# frozen_string_literal: true

module AhaSend
  # The API's answer to a send: one entry per recipient. `id` and `status`
  # expose the first entry for convenience; `messages` has them all.
  class DeliveryResult
    Message = Struct.new(:id, :status, :recipient, :error, :schedule, keyword_init: true) do
      def error? = status == "error"
    end

    attr_reader :raw, :messages

    def initialize(raw)
      @raw = raw
      data = raw.is_a?(Hash) ? Array(raw["data"]) : []
      @messages = data.map do |entry|
        Message.new(
          id: entry["id"],
          status: entry["status"],
          recipient: entry.dig("recipient", "email"),
          error: entry["error"],
          schedule: entry["schedule"]
        )
      end
    end

    # RFC 822 Message-ID of the first message, e.g. "<uuid@example.com>".
    def id = messages.first&.id
    def status = messages.first&.status
    def failed = messages.select(&:error?)
    def success? = failed.empty?
  end
end
