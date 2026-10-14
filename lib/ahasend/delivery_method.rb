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
  # read_timeout, max_retries (client); plus any message option except
  # idempotency_key (tags, tracking, sandbox, ...) as a default for every
  # message. Settings are validated on first use, not at boot.
  class DeliveryMethod
    # ActiveSupport::Notifications event emitted around every API call, when
    # ActiveSupport is loaded. Payload: :mail_message_id (the ID Rails logged
    # in deliver.action_mailer), :endpoint, :sandbox, and after a response
    # :message_ids, :recipients (email/status/id/error), :failed_recipients
    # and :replayed. No credentials or message content.
    NOTIFICATION = "deliver.ahasend"

    attr_reader :settings

    def initialize(settings = {})
      @settings = settings.to_h.transform_keys(&:to_sym)
    end

    # Sends the message and returns an AhaSend::DeliveryResult. The
    # Message-ID AhaSend assigned to the first accepted recipient is written
    # back onto the mail object.
    #
    # Raises DeliveryError only when the API rejected every recipient. When
    # some were accepted it returns normally: raising would make a retried
    # job (which sends with a new Idempotency-Key) deliver a second copy to
    # the recipients who already got one. The rejected recipients are in
    # DeliveryResult#failed and the notification's :failed_recipients.
    def deliver!(mail)
      built = MessagePayload.build(mail, defaults: settings.except(*Client::SETTINGS))
      instrument(mail, built) do |event|
        response = client.send_message(built.payload, conversation: built.conversation?,
                                                      idempotency_key: built.idempotency_key)
        result = DeliveryResult.from_response(response)
        event.merge!(result.to_notification)
        raise DeliveryError, result if result.accepted.empty?

        mail.message_id = result.accepted.first.id
        result
      end
    end

    def client
      @client ||= Client.new(**settings.slice(*Client::SETTINGS))
    end

    private

    def instrument(mail, built, &)
      event = { mail_message_id: mail.message_id, endpoint: built.endpoint, sandbox: built.payload["sandbox"] == true }
      return yield(event) unless defined?(ActiveSupport::Notifications)

      ActiveSupport::Notifications.instrument(NOTIFICATION, event, &)
    end
  end
end
