# frozen_string_literal: true

# Entry point. Bundler auto-requires this file for `gem "ahasend-rails"`.
require "mail"

require_relative "ahasend/version"
require_relative "ahasend/errors"
require_relative "ahasend/client"
require_relative "ahasend/message_options"
require_relative "ahasend/message_payload"
require_relative "ahasend/delivery_result"
require_relative "ahasend/delivery_method"
require_relative "ahasend/railtie" if defined?(Rails::Railtie)
