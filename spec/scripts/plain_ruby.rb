# frozen_string_literal: true

# Delivers through the plain mail gem with no Rails or ActiveSupport loaded.
# Run in a separate process by spec/plain_ruby_spec.rb, and by CI's
# plain-ruby job against gemfiles/plain_ruby.gemfile, which does not install
# Rails at all. Fake HTTP only (WebMock).

require "webmock"
require "ahasend-rails"

include WebMock::API # rubocop:disable Style/MixinUsage

WebMock.enable!
WebMock.disable_net_connect!

loaded = %w[Rails ActionMailer ActiveSupport].select { |name| Object.const_defined?(name) }
abort "plain ruby check failed: #{loaded.join(", ")} loaded" unless loaded.empty?

stub = stub_request(:post, "https://api.ahasend.com/v2/accounts/acc-1/messages").to_return(
  status: 202,
  headers: { "Content-Type" => "application/json" },
  body: JSON.generate("object" => "list", "data" => [{ "object" => "message", "id" => "<1@ahasend.test>", "status" => "queued",
                                                       "recipient" => { "email" => "user@example.com", "name" => "" },
                                                       "error" => nil }])
)

Mail.defaults do
  delivery_method AhaSend::DeliveryMethod, api_key: "aha-sk-plain", account_id: "acc-1", tags: ["plain"]
end

mail = Mail.deliver do
  from "sender@example.com"
  to "user@example.com"
  subject "Plain Ruby"
  body "No Rails here"
end

requests = WebMock::RequestRegistry.instance.times_executed(stub.request_pattern)
abort "plain ruby check failed: #{requests} requests" unless requests == 1
abort "plain ruby check failed: message_id #{mail.message_id.inspect}" unless mail.message_id == "1@ahasend.test"
abort "plain ruby check failed: Rails got loaded" if Object.const_defined?(:ActiveSupport)

puts "plain ruby ok (mail #{Mail::VERSION::STRING})"
