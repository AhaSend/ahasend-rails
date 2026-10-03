# ahasend-rails

[![CI](https://github.com/Sameer1122/ahasend-rails/actions/workflows/main.yml/badge.svg)](https://github.com/Sameer1122/ahasend-rails/actions/workflows/main.yml)

ActionMailer delivery method for the [AhaSend](https://ahasend.com) email API.
Your existing mailers keep working unchanged; mail goes out over AhaSend's
HTTPS API (v2) instead of SMTP, with attachments, inline images, tags,
open/click tracking, scheduling, sandbox mode and safe automatic retries.

Works with Rails 7.0 – 8.x on Ruby 3.1+, and with the plain
[`mail`](https://github.com/mikel/mail) gem outside Rails.

## Installation

```ruby
# Gemfile
gem "ahasend-rails"
```

You need an AhaSend **API key** with the `messages:send` scope and your
**account ID** (both in the AhaSend dashboard under *API Keys*), plus a
[verified sending domain](https://ahasend.com/docs/domains).

## Rails setup

```ruby
# config/environments/production.rb
config.action_mailer.delivery_method = :ahasend
config.action_mailer.ahasend_settings = {
  api_key: Rails.application.credentials.dig(:ahasend, :api_key),
  account_id: Rails.application.credentials.dig(:ahasend, :account_id)
}
```

That's it. `UserMailer.welcome(user).deliver_later` now sends through AhaSend.

### Settings reference

| Key | Default | Description |
| --- | --- | --- |
| `api_key` | — | **Required.** AhaSend API key (`aha-sk-...`). |
| `account_id` | — | **Required.** The account the key belongs to. |
| `base_url` | `https://api.ahasend.com` | Override for testing against a mock server. |
| `open_timeout` | `10` | Seconds to wait for the TCP/TLS connection. |
| `read_timeout` | `30` | Seconds to wait for the response. |
| `max_retries` | `2` | Retries on 429, 5xx and network errors (see [Retries](#retries-and-idempotency)). |
| `sandbox`, `tags`, `tracking`, `retention`, `schedule`, `sandbox_result` | — | Defaults applied to every message; the same keys as the [per-message options](#per-message-options). |

A common pattern is to turn on sandbox mode for staging so the API validates
everything but delivers nothing:

```ruby
# config/environments/staging.rb
config.action_mailer.ahasend_settings = { api_key: ..., account_id: ..., sandbox: true }
```

## Per-message options

AhaSend features that have no equivalent in a standard email are set either
through `AhaSend-*` headers (works from any mailer, matches the header names
AhaSend's SMTP relay understands) or through `message.ahasend` in Ruby. Ruby
options win over headers, and both win over settings-level defaults. The
headers are consumed by the gem and never sent to the API.

```ruby
class UserMailer < ApplicationMailer
  def welcome(user)
    headers["AhaSend-Tags"] = "welcome,onboarding"
    headers["AhaSend-Track-Opens"] = "true"
    headers["AhaSend-Idempotency-Key"] = "welcome-#{user.id}"

    mail(to: user.email, subject: "Welcome!")
  end

  def invoice(invoice)
    message = mail(to: invoice.customer_email, subject: "Your invoice")
    message.ahasend.tags = ["invoice"]
    message.ahasend.schedule = { first_attempt: invoice.send_at.iso8601 }
    message.ahasend.retention = { metadata: 30, data: 7 }
    message
  end
end
```

| Header | `message.ahasend` | Value |
| --- | --- | --- |
| `AhaSend-Tags` | `tags` | Comma-separated list / `Array<String>` |
| `AhaSend-Track-Opens`, `AhaSend-Track-Clicks` | `tracking` | Headers take `true`/`false`; Ruby takes a hash `{ open: true, click: false }` |
| `AhaSend-Substitutions` | `substitutions` | JSON object / `Hash` — template variables for `{{ name }}` in subject and body |
| `AhaSend-Retention-Metadata`, `AhaSend-Retention-Data` | `retention` | Days / `{ metadata:, data: }` |
| `AhaSend-Schedule-First-Attempt`, `AhaSend-Schedule-Expires` | `schedule` | RFC 3339 timestamps / `{ first_attempt:, expires: }` |
| `AhaSend-Sandbox` | `sandbox` | `true`/`false` |
| `AhaSend-Sandbox-Result` | `sandbox_result` | `deliver`, `bounce`, `defer`, `fail` or `suppress` |
| `AhaSend-Idempotency-Key` | `idempotency_key` | Any unique string (see [Retries](#retries-and-idempotency)) |

Any other custom header (`X-Campaign`, `List-Unsubscribe`, ...) is forwarded
to AhaSend as a message header.

## How messages map to the API

- **No Cc/Bcc** → `POST /messages`. Each `To` address receives its own copy
  and recipients do not see one another.
- **Any Cc or Bcc** → `POST /messages/conversation`. One message is sent with
  the full To/Cc/Bcc headers, the way a regular mail client would.
- `from`, `reply_to`, `subject`, text/HTML/AMP parts, attachments and inline
  images (`attachments.inline[...]`, referenced by `cid:`) are mapped directly.
- AhaSend assigns the `Message-ID`; after delivery it is available as
  `message.message_id`.

## Delivery results and errors

`deliver_now` / `deliver!` return as usual. The delivery method itself returns
an `AhaSend::DeliveryResult` with one entry per recipient:

```ruby
result = AhaSend::DeliveryMethod.new(settings).deliver!(mail)
result.id        # => "<4f1e...@ahasend.com>"
result.status    # => "queued" (or "scheduled")
result.messages  # => [#<struct id:, status:, recipient:, error:, schedule:>, ...]
```

Errors are typed, so you can rescue what you care about:

| Error | When |
| --- | --- |
| `AhaSend::ConfigurationError` | `api_key` or `account_id` missing |
| `AhaSend::ValidationError` | 400 / 422 — bad address, unverified domain, ... (`error.body` has the API's message) |
| `AhaSend::AuthenticationError` | 401 / 403 |
| `AhaSend::RateLimitError` | 429 after retries are exhausted (`error.retry_after`) |
| `AhaSend::IdempotencyError` | 409 / 412, or 422 with `Idempotent-Replayed` — the key is still in flight, its original request failed, or it was reused with a different payload |
| `AhaSend::UnexpectedResponseError` | 2xx without the documented message list — delivery state unknown |
| `AhaSend::ServerError` | 5xx after retries are exhausted |
| `AhaSend::ConnectionError` | No HTTP response (timeout, DNS, TLS); the cause is in `error.cause` |
| `AhaSend::DeliveryError` | The API accepted the request but reported `status: "error"` for a recipient; `error.result` has the breakdown |

All of them inherit from `AhaSend::Error`. With ActionMailer's default
`raise_delivery_errors = true` they propagate out of `deliver_now` (and fail the
job for `deliver_later`).

## Retries and idempotency

Every request carries an `Idempotency-Key`. If you don't set one, the gem
generates a UUID per delivery. Because of that, retrying is safe: a request
the API already processed is answered from its cache instead of sending the
email again.

The client retries on 429, 500, 502, 503, 504 and on network failures, waiting
for the API's `Retry-After` when present (capped at 30 s) and otherwise using
exponential backoff with jitter (0.5 s, 1 s, 2 s, ... capped at 8 s).
`max_retries: 0` turns this off. Client errors (400, 401, 404, ...) are never retried.

Set your own key when you want *your* retries to be safe too, for example when
a background job may run twice:

```ruby
headers["AhaSend-Idempotency-Key"] = "order-confirmation-#{order.id}"
```

## Without Rails

```ruby
require "ahasend-rails"

Mail.defaults do
  delivery_method AhaSend::DeliveryMethod, api_key: "aha-sk-...", account_id: "..."
end

Mail.deliver do
  from    "noreply@example.com"
  to      "someone@example.com"
  subject "Hello"
  body    "Sent through AhaSend"
end
```

## Testing your app

Keep ActionMailer's `:test` delivery method in your test environment as usual;
nothing here changes that. To exercise the real API without delivering, use
`sandbox: true` in `ahasend_settings` (optionally with `sandbox_result:` to
simulate bounces and failures).

## Development

```sh
bundle install
bundle exec rake            # rspec + rubocop (offline; HTTP is stubbed with WebMock)
bin/console                 # IRB with the gem loaded
```

`bin/live_check` runs a set of sandbox sends against the real API:

```sh
AHASEND_API_KEY=aha-sk-... AHASEND_ACCOUNT_ID=... AHASEND_FROM_EMAIL=you@verified-domain.com bin/live_check
```

## Releasing

Releases are published to RubyGems.org by GitHub Actions through
[Trusted Publishing](https://guides.rubygems.org/trusted-publishing/); no API
key is stored in the repository.

1. Bump `AhaSend::VERSION` in `lib/ahasend/version.rb` and move the
   `Unreleased` notes in `CHANGELOG.md` under the new version.
2. Commit, then create a GitHub release tagged `vX.Y.Z`.
3. The `Release` workflow verifies the tag matches the version, runs the
   suite and pushes the gem.

## License

MIT
