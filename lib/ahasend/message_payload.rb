# frozen_string_literal: true

module AhaSend
  # Translates a Mail::Message into the JSON body for the AhaSend send
  # endpoints and decides which endpoint it belongs to:
  #
  #   * To only            -> POST /messages, a separate message per To address
  #   * To with Cc/Bcc     -> POST /messages/conversation, one message carrying
  #                           the full To/Cc/Bcc headers
  #   * Bcc only, no To    -> POST /messages, a separate message per Bcc
  #                           address, so no recipient sees another
  #   * smtp_envelope_to   -> POST /messages to the envelope addresses only,
  #     set explicitly        e.g. by an interceptor redirecting delivery
  #
  # Cc without any To, and substitutions on the conversation endpoint (which
  # does not support them), raise MessageError instead of sending something
  # other than what was built.
  #
  # AhaSend options come from settings defaults, `AhaSend-*` headers and
  # `message.ahasend` (see Options). The headers are consumed, never
  # forwarded to the API.
  class MessagePayload
    Built = Struct.new(:payload, :conversation, :idempotency_key, keyword_init: true) do
      def conversation? = conversation
      def endpoint = conversation ? :conversation : :messages
    end

    # Headers that are mapped to dedicated payload fields or that the API
    # regenerates itself; everything else is forwarded under `headers`.
    CONSUMED_HEADERS = %w[
      from to cc bcc reply-to subject date message-id mime-version
      content-type content-transfer-encoding content-disposition content-id
      return-path received delivered-to
    ].freeze

    OPTION_FIELDS = %i[tags substitutions tracking retention schedule sandbox sandbox_result].freeze

    # Per-request recipient limits (CreateMessageRequest.recipients and the
    # conversation endpoint's combined To + Cc + Bcc).
    MAX_RECIPIENTS = 100
    MAX_CONVERSATION_RECIPIENTS = 50

    def self.build(mail, defaults: {})
      new(mail, defaults: defaults).build
    end

    def initialize(mail, defaults: {})
      @mail = mail
      @defaults = defaults.to_h.transform_keys(&:to_sym)
    end

    def build
      options = Options.merge(
        Options.from_settings(@defaults),
        Options.from_headers(mail),
        Options.from_message_options(mail.ahasend)
      )
      conversation, recipients = routing
      check_recipient_limit!(conversation, recipients)
      if conversation && !options.fetch(:substitutions, {}).empty?
        raise MessageError,
              "substitutions cannot be combined with Cc/Bcc: AhaSend's conversation endpoint does not support " \
              "them, so the template would be sent unrendered. Remove the substitutions or the Cc/Bcc recipients."
      end

      payload = base_payload.merge(recipients).merge(option_fields(options))
      Built.new(payload: payload, conversation: conversation, idempotency_key: options[:idempotency_key])
    end

    private

    attr_reader :mail

    # Returns [conversation?, recipient fields].
    def routing
      envelope = envelope_override
      return [false, { "recipients" => envelope.map { |email| { "email" => email } } }] if envelope

      to, cc, bcc = %i[to cc bcc].map { |field| addresses(field).map { |address| address_hash(address) } }
      return header_routing(to, cc, bcc) if to.any?

      raise MessageError, "the message has Cc but no To recipient; AhaSend needs at least one To address alongside Cc" if cc.any?
      raise MessageError, "the message has no recipients" if bcc.empty?

      # Bcc only: an individual message per address keeps them hidden from
      # each other, which the conversation endpoint (To required) cannot do.
      [false, { "recipients" => bcc }]
    end

    # The API rejects larger requests with a 400; fail before sending instead.
    def check_recipient_limit!(conversation, recipients)
      count = recipients.values.sum(&:size)
      if conversation && count > MAX_CONVERSATION_RECIPIENTS
        raise MessageError, "the message has #{count} To/Cc/Bcc recipients; AhaSend accepts at most " \
                            "#{MAX_CONVERSATION_RECIPIENTS} in total on a message with Cc or Bcc"
      end
      return if conversation || count <= MAX_RECIPIENTS

      raise MessageError, "the message has #{count} recipients; AhaSend accepts at most #{MAX_RECIPIENTS} " \
                          "per message, so send it in batches"
    end

    def header_routing(to, cc, bcc)
      return [false, { "recipients" => to }] if cc.empty? && bcc.empty?

      [true, { "to" => to, "cc" => cc, "bcc" => bcc }.reject { |_, list| list.empty? }]
    end

    # An explicit `smtp_envelope_to` that differs from the To/Cc/Bcc headers
    # redirects delivery: SMTP would send only to the envelope addresses, so
    # only they become API recipients (each gets an individual message; the
    # header recipients receive nothing). Mail falls back to the header
    # addresses when no envelope is set, which compares equal here.
    def envelope_override
      envelope = Array(mail.smtp_envelope_to).map { |value| bare_address(value) }.uniq
      destinations = Array(mail.destinations).map { |value| bare_address(value) }.uniq
      return nil if envelope.map(&:downcase).sort == destinations.map(&:downcase).sort
      raise MessageError, "smtp_envelope_to is set but empty; there is no one to deliver to" if envelope.empty?

      envelope
    end

    def bare_address(value)
      address = Mail::Address.new(value.to_s).address
      raise MessageError, "#{value.inspect} is not a valid email address" if address.to_s.empty?

      address
    rescue Mail::Field::ParseError
      raise MessageError, "#{value.inspect} is not a valid email address"
    end

    def base_payload
      from = addresses(:from).first
      raise MessageError, "the message has no From address" if from.nil?

      {
        "from" => address_hash(from),
        "reply_to" => addresses(:reply_to).first&.then { |address| address_hash(address) },
        "subject" => mail.subject.to_s,
        "text_content" => part_body("text/plain"),
        "html_content" => part_body("text/html"),
        "amp_content" => part_body("text/x-amp-html"),
        "attachments" => (attachments if mail.attachments.any?),
        "headers" => (custom_headers unless custom_headers.empty?)
      }.compact
    end

    def option_fields(options)
      OPTION_FIELDS.each_with_object({}) do |name, fields|
        value = options[name]
        next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

        fields[name.to_s] = value
      end
    end

    def addresses(field_name)
      field = mail[field_name]
      return [] if field.nil?

      field = field.first if field.is_a?(Array)
      field.respond_to?(:addrs) ? field.addrs : []
    end

    def address_hash(address)
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
          "data" => [part.body.decoded].pack("m0"), # strict Base64, no base64 gem needed (Ruby 3.4+)
          "base64" => true
        }
        if part.inline?
          attachment["content_disposition"] = "inline"
          attachment["content_id"] = content_id(part)
        end
        attachment
      end
    end

    # The MIME Content-ID with its angle brackets, as the API requires
    # (`<logo@example.com>`); without them AhaSend delivers the file as a
    # regular attachment. The HTML references it bracket-free
    # (`cid:logo@example.com`, which is what `attachments[...].url` returns).
    # Mail generates a random ID when the attachment was given none; pass
    # `content_id:` when attaching for an ID that is stable across rebuilds.
    def content_id(part)
      part.add_content_id unless part.has_content_id?
      "<#{part.content_id.to_s.strip.delete_prefix("<").delete_suffix(">")}>"
    end

    def custom_headers
      @custom_headers ||= mail.header.fields.each_with_object({}) do |field, headers|
        name = field.name.to_s
        key = name.downcase
        next if CONSUMED_HEADERS.include?(key) || key.start_with?(Options::HEADER_PREFIX)

        value = field.value.to_s
        headers[name] = headers.key?(name) ? "#{headers[name]}, #{value}" : value
      end
    end
  end
end
