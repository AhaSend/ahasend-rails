# ahasend-rails

ActionMailer delivery method for the [AhaSend](https://ahasend.com) email API (v2).
Sends Rails mail through AhaSend's HTTP API instead of SMTP, with support for
attachments, inline images, tags, open/click tracking, scheduling, sandbox mode
and idempotent retries.

Work in progress — full documentation and usage examples are coming with the
first release.

## Quick start

```ruby
# Gemfile
gem "ahasend-rails"

# config/environments/production.rb
config.action_mailer.delivery_method = :ahasend
config.action_mailer.ahasend_settings = {
  api_key: Rails.application.credentials.dig(:ahasend, :api_key),
  account_id: Rails.application.credentials.dig(:ahasend, :account_id)
}
```

## Development

```sh
bundle install
bundle exec rspec     # unit tests (offline, WebMock)
bundle exec rubocop
```

## License

MIT
