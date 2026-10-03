# frozen_string_literal: true

module AhaSend
  class Railtie < ::Rails::Railtie
    # Must run before ActionMailer's own `set_configs` hook, which assigns
    # every `config.action_mailer.*` option (including `ahasend_settings`)
    # and needs the accessor that add_delivery_method defines.
    initializer "ahasend.add_delivery_method", before: "action_mailer.set_configs" do
      ActiveSupport.on_load(:action_mailer) do
        add_delivery_method :ahasend, AhaSend::DeliveryMethod
      end
    end
  end
end
