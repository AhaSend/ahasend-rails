# frozen_string_literal: true

require "rails"
require "action_mailer/railtie"
require "ahasend/railtie"

# A minimal host application, booted the way a real Rails app would be. Rails
# derives the app name from the class name, so this has to be a real constant.
module HostApp
  class Application < ::Rails::Application
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.active_support.deprecation = :silence
    config.action_mailer.delivery_method = :ahasend
    config.action_mailer.ahasend_settings = { api_key: "k", account_id: "a", sandbox: true }
  end
end

# Proves that config.action_mailer.ahasend_settings survives ActionMailer's
# own config hook, which is the ordering the Railtie guards against.
RSpec.describe AhaSend::Railtie do
  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    HostApp::Application.initialize!
    ActionMailer::Base # trigger on_load
  end

  it "registers the delivery method with the configured settings" do
    expect(ActionMailer::Base.delivery_methods[:ahasend]).to eq(AhaSend::DeliveryMethod)
    expect(ActionMailer::Base.delivery_method).to eq(:ahasend)
    expect(ActionMailer::Base.ahasend_settings).to eq(api_key: "k", account_id: "a", sandbox: true)
  end
end
