# frozen_string_literal: true

module AhaSend
  # Per-message AhaSend options set from Ruby rather than headers:
  #
  #   message = mail(to: ..., subject: ...)
  #   message.ahasend.tags = %w[welcome onboarding]
  #   message.ahasend.tracking = { open: true, click: false }
  #
  # Anything set here overrides the equivalent `AhaSend-*` header.
  class MessageOptions
    ATTRIBUTES = %i[tags substitutions tracking retention schedule sandbox sandbox_result idempotency_key].freeze

    attr_accessor(*ATTRIBUTES)

    def initialize(**attrs)
      attrs.each { |key, value| public_send(:"#{key}=", value) }
    end

    def to_h
      ATTRIBUTES.each_with_object({}) do |key, hash|
        value = public_send(key)
        hash[key] = value unless value.nil?
      end
    end
  end

  # Adds `Mail::Message#ahasend`.
  module MailExtension
    def ahasend
      @ahasend ||= MessageOptions.new
    end
  end
end

Mail::Message.include(AhaSend::MailExtension)
