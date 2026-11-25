# frozen_string_literal: true

require "json"

module AhaSend
  # Reads, validates and merges the AhaSend-specific message options (tags,
  # tracking, retention, ...). They can be set in three places, in increasing
  # precedence:
  #
  #   1. `ahasend_settings` defaults   -> errors raise ConfigurationError
  #   2. `AhaSend-*` message headers   -> errors raise MessageError
  #   3. `message.ahasend` in Ruby     -> errors raise MessageError
  #
  # Every layer is normalised to the same shape (Symbol option names, String
  # keys inside nested hashes), so `{ open: true }` and `{ "open" => true }`
  # mean the same thing, and nested options merge field by field: a header
  # that sets only the metadata retention keeps a default data retention.
  module Options
    NESTED_FIELDS = {
      tracking: %w[open click],
      retention: %w[metadata data],
      schedule: %w[first_attempt expires]
    }.freeze

    SANDBOX_RESULTS = %w[deliver bounce defer fail suppress].freeze
    BOOLEANS = {
      "true" => true, "1" => true, "yes" => true, "on" => true,
      "false" => false, "0" => false, "no" => false, "off" => false
    }.freeze
    MAX_IDEMPOTENCY_KEY_LENGTH = 255

    HEADER_PREFIX = "ahasend-"

    # Header (lower case) => [option, nested field, parser]. The first seven
    # are the special headers AhaSend's SMTP relay understands, under the same
    # names; the rest have no SMTP equivalent.
    HEADERS = {
      "ahasend-tags" => [:tags, nil, :list],
      "ahasend-track-opens" => [:tracking, "open", :boolean],
      "ahasend-track-clicks" => [:tracking, "click", :boolean],
      "ahasend-sandbox" => [:sandbox, nil, :boolean],
      "ahasend-sandbox-result" => [:sandbox_result, nil, :string],
      "ahasend-metadata-retention" => [:retention, "metadata", :integer],
      "ahasend-data-retention" => [:retention, "data", :integer],
      "ahasend-substitutions" => [:substitutions, nil, :json_object],
      "ahasend-schedule-first-attempt" => [:schedule, "first_attempt", :string],
      "ahasend-schedule-expires" => [:schedule, "expires", :string],
      "ahasend-idempotency-key" => [:idempotency_key, nil, :string]
    }.freeze

    module_function

    # Defaults from `ahasend_settings` (with the client's own settings already
    # removed). An idempotency key must be unique per message, so it is not
    # accepted as a default.
    def from_settings(settings)
      if settings.key?(:idempotency_key)
        raise ConfigurationError,
              "ahasend_settings[:idempotency_key] is not allowed: a key must be unique per message, " \
              "set it with the AhaSend-Idempotency-Key header or message.ahasend.idempotency_key"
      end

      validate(settings, ConfigurationError) { |name| "ahasend_settings[:#{name}]" }
    end

    # Options set in Ruby through `message.ahasend`.
    def from_message_options(options)
      validate(options.to_h, MessageError) { |name| "message.ahasend.#{name}" }
    end

    # Options set through `AhaSend-*` headers. Header names are
    # case-insensitive; an unknown AhaSend-* header is an error rather than
    # being dropped, so a misspelt `AhaSend-Sandbox` cannot turn into a real
    # send. When a header appears twice, the last one wins.
    def from_headers(mail)
      mail.header.fields.each_with_object({}) do |field, options|
        name = field.name.to_s
        next unless name.downcase.start_with?(HEADER_PREFIX)

        option, nested, parser = HEADERS.fetch(name.downcase) { unknown_header!(name) }
        raw = field.value.to_s.strip
        next if raw.empty?

        parsed = parse_header(name, raw, parser)
        value = normalize(option, nested ? { nested => parsed } : parsed, name, MessageError)
        options[option] = nested ? (options[option] || {}).merge(value) : value
      end
    end

    # Merges layers in increasing precedence. Nested hashes (tracking,
    # retention, schedule, substitutions) merge per field; everything else is
    # replaced by the later layer.
    def merge(*layers)
      layers.each_with_object({}) do |layer, merged|
        layer.each do |name, value|
          merged[name] = merged[name].is_a?(Hash) && value.is_a?(Hash) ? merged[name].merge(value) : value
        end
      end
    end

    def validate(hash, error)
      hash.each_with_object({}) do |(name, value), options|
        next if value.nil?

        name = name.to_sym
        options[name] = normalize(name, value, yield(name), error)
      end
    end

    def normalize(name, value, label, error)
      case name
      when :tags then tags!(value, label, error)
      when :substitutions then hash!(value, label, error).transform_keys(&:to_s)
      when :tracking, :retention, :schedule then nested!(name, value, label, error)
      when :sandbox then boolean!(value, label, error)
      when :sandbox_result then sandbox_result!(value, label, error)
      when :idempotency_key then idempotency_key!(value, label, error)
      else raise error, "#{label} is not a supported AhaSend option"
      end
    end

    def nested!(name, value, label, error)
      fields = hash!(value, label, error).transform_keys(&:to_s)
      unknown = fields.keys - NESTED_FIELDS.fetch(name)
      raise error, "#{label} has unknown key(s) #{unknown.join(", ")}; expected #{NESTED_FIELDS[name].join(", ")}" if unknown.any?

      fields.each_with_object({}) do |(field, field_value), normalized|
        next if field_value.nil?

        normalized[field] = nested_field!(name, field_value, "#{label}[:#{field}]", error)
      end
    end

    def nested_field!(name, value, label, error)
      case name
      when :tracking then boolean!(value, label, error)
      when :retention
        return value if value.is_a?(Integer)

        raise error, "#{label} must be a whole number of days, got #{value.inspect}"
      when :schedule then timestamp!(value, label, error)
      end
    end

    def tags!(value, label, error)
      return value if value.is_a?(Array) && value.all? { |tag| tag.is_a?(String) && !tag.strip.empty? }

      raise error, "#{label} must be an Array of non-empty Strings, got #{value.inspect}"
    end

    def hash!(value, label, error)
      return value if value.is_a?(Hash)

      raise error, "#{label} must be a Hash, got #{value.inspect}"
    end

    def boolean!(value, label, error)
      return value if [true, false].include?(value)

      BOOLEANS.fetch(value.to_s.strip.downcase) do
        raise error, "#{label} must be true or false, got #{value.inspect}"
      end
    end

    def timestamp!(value, label, error)
      return value.iso8601 if value.respond_to?(:iso8601) && !value.is_a?(String)
      return value if value.is_a?(String) && !value.strip.empty?

      raise error, "#{label} must be an RFC 3339 timestamp String or a Time, got #{value.inspect}"
    end

    def sandbox_result!(value, label, error)
      return value if SANDBOX_RESULTS.include?(value)

      raise error, "#{label} must be one of #{SANDBOX_RESULTS.join(", ")}, got #{value.inspect}"
    end

    def idempotency_key!(value, label, error)
      return value if value.is_a?(String) && !value.strip.empty? && value.length <= MAX_IDEMPOTENCY_KEY_LENGTH

      raise error, "#{label} must be a non-empty String of at most #{MAX_IDEMPOTENCY_KEY_LENGTH} characters"
    end

    def parse_header(name, raw, parser)
      case parser
      when :string then raw
      when :list then raw.split(",").map(&:strip).reject(&:empty?)
      when :boolean then BOOLEANS.fetch(raw.downcase) { raise MessageError, "#{name} must be true or false, got #{raw.inspect}" }
      when :integer then parse_integer_header(name, raw)
      when :json_object then parse_json_header(name, raw)
      end
    end

    def parse_integer_header(name, raw)
      Integer(raw, 10)
    rescue ArgumentError
      raise MessageError, "#{name} must be a whole number of days, got #{raw.inspect}"
    end

    def parse_json_header(name, raw)
      parsed = JSON.parse(raw)
      return parsed if parsed.is_a?(Hash)

      raise MessageError, "#{name} must be a JSON object, got #{raw.inspect}"
    rescue JSON::ParserError => e
      raise MessageError, "#{name} is not valid JSON (#{e.message.lines.first.strip})"
    end

    def unknown_header!(name)
      supported = HEADERS.keys.map { |key| key.split("-").map(&:capitalize).join("-").sub("Ahasend", "AhaSend") }
      raise MessageError, "unknown header #{name}; supported AhaSend headers are #{supported.join(", ")}"
    end
  end
end
