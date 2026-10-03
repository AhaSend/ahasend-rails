# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# CI pins a Rails series via RAILS_VERSION (see .github/workflows/main.yml);
# local development tracks the newest supported series.
RAILS = ENV.fetch("RAILS_VERSION", "~> 8.0")
gem "actionmailer", RAILS
gem "railties", RAILS
# CI also pins the oldest supported mail gem on one cell.
gem "mail", ENV["MAIL_VERSION"] if ENV["MAIL_VERSION"]

gem "irb"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
gem "rubocop", "~> 1.70"
gem "rubocop-rspec", "~> 3.0"
gem "webmock", "~> 3.24"

# Windows has no zoneinfo directory; Rails boot (railtie_spec) needs it.
gem "tzinfo-data", platforms: %i[mingw mswin x64_mingw windows]
