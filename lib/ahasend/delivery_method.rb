# frozen_string_literal: true

module AhaSend
  # Mail / ActionMailer delivery method.
  #
  #   # Rails
  #   config.action_mailer.delivery_method = :ahasend
  #   config.action_mailer.ahasend_settings = { api_key: "...", account_id: "..." }
  #
  #   # Plain Mail
  #   Mail.defaults { delivery_method AhaSend::DeliveryMethod, api_key: "...", account_id: "..." }
  #
  # Settings: api_key, account_id (required); base_url, open_timeout,
  # read_timeout, max_retries (client); plus any MessageOptions attribute
  # (tags, tracking, sandbox, ...) as a default for every message.
  class DeliveryMethod
    CLIENT_SETTINGS = %i[api_key account_id base_url open_timeout read_timeout max_retries].freeze

    attr_reader :settings

    def initialize(settings = {})
      @settings = settings.to_h.transform_keys(&:to_sym)
    end

    # Sends the message and returns an AhaSend::DeliveryResult. The Message-ID
    # assigned by AhaSend is written back onto the mail object.
    def deliver!(mail)
      built = MessagePayload.build(mail, defaults: settings)
      response = client.send_message(built.payload, conversation: built.conversation?,
                                                    idempotency_key: built.idempotency_key)
      result = DeliveryResult.new(response)
      mail.message_id = result.id if result.id
      raise DeliveryError, result unless result.success?

      result
    end

    def client
      @client ||= Client.new(**settings.slice(*CLIENT_SETTINGS))
    end
  end
end
