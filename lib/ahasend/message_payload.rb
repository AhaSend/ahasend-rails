# frozen_string_literal: true

require "base64"
require "json"

module AhaSend
  # Translates a Mail::Message into the JSON body for the AhaSend send
  # endpoints and decides which endpoint it belongs to.
  #
  # Endpoint selection mirrors the Swoosh and TypeScript integrations:
  #   * no Cc/Bcc   -> POST /messages, one message per `To` recipient
  #   * any Cc/Bcc  -> POST /messages/conversation, a single message that
  #                    carries the full To/Cc/Bcc headers
  #
  # AhaSend-specific behaviour is read from `AhaSend-*` headers (so it works
  # from any Mail producer, and matches AhaSend's SMTP header names) and from
  # `message.ahasend` (see MessageOptions). Those headers are consumed, never
  # forwarded to the API.
  class MessagePayload
    Built = Struct.new(:payload, :conversation, :idempotency_key, keyword_init: true) do
      def conversation? = conversation
    end

    # Headers that are mapped to dedicated payload fields or that the API
    # regenerates itself; everything else is forwarded under `headers`.
    CONSUMED_HEADERS = %w[
      from to cc bcc reply-to subject date message-id mime-version
      content-type content-transfer-encoding content-disposition content-id
      return-path received delivered-to
    ].freeze

    OPTION_HEADER_PREFIX = "ahasend-"
    TRUTHY = %w[true 1 yes on].freeze

    def self.build(mail, defaults: {})
      new(mail, defaults: defaults).build
    end

    def initialize(mail, defaults: {})
      @mail = mail
      @defaults = defaults.to_h.transform_keys(&:to_sym)
    end

    def build
      options = resolved_options
      payload = base_payload.merge(option_fields(options)).compact

      Built.new(payload: payload, conversation: conversation?, idempotency_key: options[:idempotency_key])
    end

    private

    attr_reader :mail

    def conversation?
      addresses(:cc).any? || addresses(:bcc).any?
    end

    def base_payload
      payload = { "from" => address_hash(addresses(:from).first) }
      payload.merge!(recipient_fields)
      payload["reply_to"] = address_hash(addresses(:reply_to).first) if addresses(:reply_to).any?
      payload["subject"] = mail.subject.to_s
      payload["text_content"] = part_body("text/plain")
      payload["html_content"] = part_body("text/html")
      payload["amp_content"] = part_body("text/x-amp-html")
      payload["attachments"] = attachments if mail.attachments.any?
      payload["headers"] = custom_headers unless custom_headers.empty?
      payload
    end

    def recipient_fields
      to = addresses(:to).map { |a| address_hash(a) }
      return { "recipients" => to } unless conversation?

      fields = { "to" => to }
      fields["cc"] = addresses(:cc).map { |a| address_hash(a) } if addresses(:cc).any?
      fields["bcc"] = addresses(:bcc).map { |a| address_hash(a) } if addresses(:bcc).any?
      fields
    end

    # Settings-level defaults < AhaSend-* headers < message.ahasend options.
    def resolved_options
      @defaults.slice(*MessageOptions::ATTRIBUTES)
               .merge(header_options)
               .merge(mail.ahasend.to_h)
    end

    def option_fields(options)
      {
        "tags" => options[:tags],
        "substitutions" => options[:substitutions],
        "tracking" => options[:tracking],
        "retention" => options[:retention],
        "schedule" => options[:schedule],
        "sandbox" => options[:sandbox],
        "sandbox_result" => options[:sandbox_result]
      }
    end

    def header_options
      {
        tags: list_header("AhaSend-Tags"),
        substitutions: json_header("AhaSend-Substitutions"),
        tracking: presence(open: bool_header("AhaSend-Track-Opens"), click: bool_header("AhaSend-Track-Clicks")),
        retention: presence(metadata: integer_header("AhaSend-Retention-Metadata"),
                            data: integer_header("AhaSend-Retention-Data")),
        schedule: presence(first_attempt: header("AhaSend-Schedule-First-Attempt"),
                           expires: header("AhaSend-Schedule-Expires")),
        sandbox: bool_header("AhaSend-Sandbox"),
        sandbox_result: header("AhaSend-Sandbox-Result"),
        idempotency_key: header("AhaSend-Idempotency-Key")
      }.compact
    end

    # A nested option hash is only sent when at least one of its keys was set.
    def presence(**fields)
      fields = fields.compact
      fields.empty? ? nil : fields
    end

    def header(name)
      field = mail[name]
      return nil if field.nil?

      value = (field.is_a?(Array) ? field.last : field).value.to_s.strip
      value.empty? ? nil : value
    end

    def list_header(name)
      header(name)&.then { |value| value.split(",").map(&:strip).reject(&:empty?) }
    end

    def json_header(name)
      header(name)&.then { |value| JSON.parse(value) }
    end

    def integer_header(name)
      header(name)&.then { |value| Integer(value, 10) }
    end

    def bool_header(name)
      header(name)&.then { |value| TRUTHY.include?(value.downcase) }
    end

    def addresses(field_name)
      field = mail[field_name]
      return [] if field.nil?

      field = field.first if field.is_a?(Array)
      field.respond_to?(:addrs) ? field.addrs : []
    end

    def address_hash(address)
      return nil if address.nil?

      hash = { "email" => address.address }
      name = address.display_name
      hash["name"] = name unless name.nil? || name.empty?
      hash
    end

    def part_body(mime_type)
      part =
        if mail.multipart?
          mail.find_first_mime_type(mime_type)
        elsif (mail.mime_type || "text/plain") == mime_type && !mail.attachment?
          mail
        end
      return nil if part.nil?

      body = part.decoded
      body.empty? ? nil : body
    end

    def attachments
      mail.attachments.map do |part|
        attachment = {
          "file_name" => part.filename,
          "content_type" => part.mime_type,
          "data" => Base64.strict_encode64(part.body.decoded),
          "base64" => true
        }
        if part.inline?
          part.cid unless part.has_content_id? # Mail assigns the Content-ID lazily
          attachment["content_disposition"] = "inline"
          attachment["content_id"] = Mail::Utilities.unbracket(part.content_id.to_s)
        end
        attachment
      end
    end

    def custom_headers
      @custom_headers ||= mail.header.fields.each_with_object({}) do |field, headers|
        name = field.name.to_s
        key = name.downcase
        next if CONSUMED_HEADERS.include?(key) || key.start_with?(OPTION_HEADER_PREFIX)

        value = field.value.to_s
        headers[name] = headers.key?(name) ? "#{headers[name]}, #{value}" : value
      end
    end
  end
end
