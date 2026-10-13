# frozen_string_literal: true

# A minimal Rails host application, booted the way a real one is: Rails and
# its frameworks first, then the gem through its public entry point (what
# Bundler.require does). Runs the delivery-lifecycle scenarios and prints the
# results as one JSON line. spec/host_app_spec.rb runs this in a separate
# process, so Rails' global state never leaks into the rest of the suite.
# Fake HTTP only (WebMock).

require "logger" # Rails 7.0 needs Logger loaded before ActiveSupport
require "json"
require "tmpdir"
require "rails"
require "action_mailer/railtie"
require "active_job/railtie"
require "webmock"
require "ahasend-rails"

include WebMock::API # rubocop:disable Style/MixinUsage

WebMock.enable!
WebMock.disable_net_connect!

module HostApp
  class Application < Rails::Application
    config.root = Dir.mktmpdir("ahasend-host-app")
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.active_support.deprecation = :silence
    config.active_job.queue_adapter = :test
    config.action_mailer.delivery_method = :ahasend
    config.action_mailer.ahasend_settings = { api_key: "aha-sk-host", account_id: "acc-1", max_retries: 0, sandbox: true }
  end
end
HostApp::Application.initialize!
ActiveJob::Base.logger = Logger.new(IO::NULL)

class WelcomeMailer < ActionMailer::Base
  default from: "Acme <noreply@acme.test>"

  # Options set inside the action, the supported pattern for deliver_later:
  # the job re-runs the action, so they are rebuilt with the message.
  def welcome(email)
    headers["AhaSend-Tags"] = "welcome"
    message = mail(to: email, subject: "Welcome", body: "Hi")
    message.ahasend.tracking = { open: true }
    message
  end

  def other_account(email)
    mail(to: email, subject: "Other", body: "Hi", delivery_method_options: { account_id: "acc-2" })
  end
end

class RedirectToInterceptor
  def self.delivering_email(message)
    message.to = ["qa@acme.test"]
  end
end

class EnvelopeInterceptor
  def self.delivering_email(message)
    message.smtp_envelope_to = "test-inbox@acme.test"
  end
end

class RecordingObserver
  class << self
    attr_accessor :message_id
  end

  def self.delivered_email(message)
    self.message_id = message.message_id
  end
end

REQUESTS = [] # rubocop:disable Style/MutableConstant

def stub_api(status: 202)
  WebMock.reset!
  REQUESTS.clear
  stub_request(:post, %r{\Ahttps://api\.ahasend\.com/v2/accounts/[^/]+/messages}).to_return do |request|
    body = JSON.parse(request.body)
    REQUESTS << { "path" => request.uri.path, "body" => body, "idempotency_key" => request.headers["Idempotency-Key"] }
    next { status: status, body: JSON.generate("message" => "bad request") } unless status == 202

    emails = (body["recipients"] || body.values_at("to", "cc", "bcc").compact.flatten).map { |r| r["email"] }
    data = emails.each_with_index.map do |email, i|
      { "object" => "message", "id" => "<#{i}@ahasend.test>", "status" => "queued",
        "recipient" => { "email" => email, "name" => "" }, "error" => nil }
    end
    { status: 202, body: JSON.generate("object" => "list", "data" => data), headers: { "Content-Type" => "application/json" } }
  end
end

def recipients(request)
  body = request.fetch("body")
  (body["recipients"] || body.values_at("to", "cc", "bcc").compact.flatten).map { |r| r["email"] }
end

RESULTS = {} # rubocop:disable Style/MutableConstant

def check(name)
  RESULTS[name] = yield
rescue StandardError => e
  RESULTS[name] = { "error" => "#{e.class}: #{e.message}" }
end

check("railtie") do
  {
    "registered" => ActionMailer::Base.delivery_methods[:ahasend] == AhaSend::DeliveryMethod,
    "delivery_method" => ActionMailer::Base.delivery_method.to_s,
    "settings" => ActionMailer::Base.ahasend_settings.transform_keys(&:to_s)
  }
end

check("deliver_now") do
  stub_api
  message = WelcomeMailer.welcome("new@user.test").deliver_now
  request = REQUESTS.last
  { "requests" => REQUESTS.size, "path" => request["path"], "recipients" => recipients(request),
    "options" => request["body"].slice("tags", "tracking", "sandbox"), "message_id" => message.message_id }
end

check("deliver_later") do
  stub_api
  adapter = ActiveJob::Base.queue_adapter
  adapter.perform_enqueued_jobs = true
  WelcomeMailer.welcome("later@user.test").deliver_later
  request = REQUESTS.last
  { "adapter" => adapter.class.name, "job" => adapter.performed_jobs.last&.fetch(:job).to_s,
    "requests" => REQUESTS.size, "recipients" => recipients(request),
    "options" => request["body"].slice("tags", "tracking"), "idempotency_key_sent" => !request["idempotency_key"].to_s.empty? }
ensure
  adapter.perform_enqueued_jobs = false
end

check("interceptor_to") do
  stub_api
  ActionMailer::Base.register_interceptor(RedirectToInterceptor)
  WelcomeMailer.welcome("real@user.test").deliver_now
  { "recipients" => recipients(REQUESTS.last) }
ensure
  Mail.unregister_interceptor(RedirectToInterceptor)
end

check("interceptor_envelope") do
  stub_api
  ActionMailer::Base.register_interceptor(EnvelopeInterceptor)
  message = WelcomeMailer.welcome("real@user.test")
  message.cc = "boss@user.test"
  message.deliver_now
  { "path" => REQUESTS.last["path"], "recipients" => recipients(REQUESTS.last) }
ensure
  Mail.unregister_interceptor(EnvelopeInterceptor)
end

check("observer") do
  stub_api
  ActionMailer::Base.register_observer(RecordingObserver)
  WelcomeMailer.welcome("seen@user.test").deliver_now
  { "observed_message_id" => RecordingObserver.message_id }
ensure
  Mail.unregister_observer(RecordingObserver)
end

check("perform_deliveries_false") do
  stub_api
  ActionMailer::Base.perform_deliveries = false
  WelcomeMailer.welcome("skip@user.test").deliver_now
  { "requests" => REQUESTS.size }
ensure
  ActionMailer::Base.perform_deliveries = true
end

check("raise_delivery_errors_false") do
  stub_api(status: 400)
  ActionMailer::Base.raise_delivery_errors = false
  WelcomeMailer.welcome("quiet@user.test").deliver_now
  { "requests" => REQUESTS.size, "raised" => false }
ensure
  ActionMailer::Base.raise_delivery_errors = true
end

check("raise_delivery_errors_true") do
  stub_api(status: 400)
  WelcomeMailer.welcome("loud@user.test").deliver_now
  { "raised" => false }
rescue AhaSend::Error => e
  { "raised" => e.class.name }
end

check("delivery_method_options") do
  stub_api
  WelcomeMailer.other_account("other@user.test").deliver_now
  { "path" => REQUESTS.last["path"] }
end

check("notifications") do
  stub_api
  events = {}
  subscribers = %w[deliver.action_mailer deliver.ahasend].map do |name|
    ActiveSupport::Notifications.subscribe(name) { |*args| events[name] = args.last }
  end
  message = WelcomeMailer.welcome("watch@user.test").deliver_now
  ahasend = events.fetch("deliver.ahasend")
  { "rails_message_id" => events.fetch("deliver.action_mailer")[:message_id],
    "ahasend_mail_message_id" => ahasend[:mail_message_id], "ahasend_message_ids" => ahasend[:message_ids],
    "final_message_id" => message.message_id, "payload_keys" => ahasend.keys.map(&:to_s).sort }
ensure
  subscribers&.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
end

puts "AHASEND_RESULTS:#{JSON.generate("rails" => Rails.version, "mail" => Mail::VERSION::STRING, "scenarios" => RESULTS)}"
