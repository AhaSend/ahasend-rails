# ahasend-rails

[![CI](https://github.com/AhaSend/ahasend-rails/actions/workflows/main.yml/badge.svg)](https://github.com/AhaSend/ahasend-rails/actions/workflows/main.yml)

ActionMailer delivery method for the [AhaSend](https://ahasend.com) email API.
Your existing mailers keep working unchanged; mail goes out over AhaSend's
HTTPS API (v2) instead of SMTP, with attachments, inline images, tags,
open/click tracking, scheduling, sandbox mode and safe automatic retries.

Works with Rails 7.0 – 8.1 on Ruby 3.1+, and with the plain
[`mail`](https://github.com/mikel/mail) gem outside Rails.

## Installation

```ruby
# Gemfile
gem "ahasend-rails"
```

You need an AhaSend **API key** allowed to send from your domain (the
`messages:send:all` role, or the send role for that domain) and your
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

Use `deliver_later` inside web requests. `deliver_now` waits for the API,
including retries: with the default settings a single delivery can block for
about two to three minutes in the worst case (three attempts, each allowed
10 s to connect and 30 s to read, plus up to 30 s between attempts). Lower
`max_retries` and the timeouts if you must send inline.

### Settings reference

| Key | Default | Description |
| --- | --- | --- |
| `api_key` | — | **Required.** AhaSend API key (`aha-sk-...`). |
| `account_id` | — | **Required.** The account the key belongs to. |
| `base_url` | `https://api.ahasend.com` | An `http(s)` URL; override for testing against a mock server. |
| `open_timeout` | `10` | Seconds (positive number) to wait for the TCP/TLS connection. |
| `read_timeout` | `30` | Seconds (positive number) to wait for the response. |
| `max_retries` | `2` | Retries (Integer ≥ 0) on 429, 5xx, network errors and in-progress requests (see [Retries](#retries-and-idempotency)). |
| `sandbox`, `tags`, `tracking`, `retention`, `schedule`, `sandbox_result`, `substitutions` | — | Defaults for every message; the same keys and values as the [per-message options](#per-message-options). |

Settings are checked the first time a message is sent, not when the app
boots, so test and development environments using another delivery method
need no AhaSend credentials. A missing or invalid setting, or an unknown key
(a typo such as `sandbx:`), raises `AhaSend::ConfigurationError`.

A common pattern is to turn on sandbox mode for staging so the API validates
everything but delivers nothing:

```ruby
# config/environments/staging.rb
config.action_mailer.ahasend_settings = { api_key: ..., account_id: ..., sandbox: true }
```

## Per-message options

AhaSend features that have no equivalent in a standard email are set either
through `AhaSend-*` headers or through `message.ahasend` in Ruby. The headers
are consumed by the gem and never sent to the API.

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
    message.ahasend.schedule = { first_attempt: invoice.send_at } # a Time or an RFC 3339 String
    message.ahasend.retention = { metadata: 30, data: 7 }
    message
  end
end
```

Set options inside the mailer action, as above. `deliver_later` queues the
mailer's arguments, not the built message, so options must be set where the
message is built to survive the job.

| Header | `message.ahasend` | Value |
| --- | --- | --- |
| `AhaSend-Tags` | `tags` | Comma-separated list / `Array<String>` |
| `AhaSend-Track-Opens`, `AhaSend-Track-Clicks` | `tracking` | `true`/`false` / `{ open: true, click: false }` |
| `AhaSend-Metadata-Retention`, `AhaSend-Data-Retention` | `retention` | Whole days / `{ metadata: 30, data: 0 }` |
| `AhaSend-Sandbox` | `sandbox` | `true`/`false` |
| `AhaSend-Sandbox-Result` | `sandbox_result` | `deliver`, `bounce`, `defer`, `fail` or `suppress` |
| `AhaSend-Substitutions` | `substitutions` | JSON object / `Hash` of template variables for `{{ name }}` in the subject and body |
| `AhaSend-Schedule-First-Attempt`, `AhaSend-Schedule-Expires` | `schedule` | RFC 3339 timestamps / `{ first_attempt:, expires: }` (Strings or Times) |
| `AhaSend-Idempotency-Key` | `idempotency_key` | A unique String of up to 255 characters (see [Retries](#retries-and-idempotency)) |

- The first five rows use the same header names as AhaSend's
  [SMTP special headers](https://ahasend.com/docs/smtp/special-headers), so an
  app moving from SMTP keeps working. Header names are case-insensitive.
- `true`/`false` also accept `1`/`0`, `yes`/`no` and `on`/`off`.
- **Precedence:** settings defaults < headers < `message.ahasend`. Nested
  options merge field by field: with a default `retention: { metadata: 30, data: 0 }`,
  a message that sets only `AhaSend-Metadata-Retention: 1` sends
  `{ metadata: 1, data: 0 }`. String and Symbol keys are equivalent.
- **Mistakes raise instead of being ignored:** a malformed value
  (`AhaSend-Sandbox: tru`, a non-numeric retention, invalid JSON) or an
  unknown `AhaSend-*` header raises `AhaSend::MessageError` naming the header,
  before anything is sent.

Any other custom header (`X-Campaign`, `List-Unsubscribe`, ...) is forwarded
to AhaSend as a message header.

## How messages map to the API

| The message has | Sent with | Result |
| --- | --- | --- |
| To only | `POST /messages` | Each To address receives its own copy; recipients do not see one another. |
| To plus Cc and/or Bcc | `POST /messages/conversation` | One message with the full To/Cc/Bcc headers, the way a mail client sends it. |
| Bcc only (no To) | `POST /messages` | Each Bcc address receives its own copy, so no recipient sees another. |
| An explicit `smtp_envelope_to` that differs from To/Cc/Bcc | `POST /messages` | Sent **only** to the envelope addresses, one copy each; the header recipients receive nothing. This is how an interceptor redirects mail (for example to a test inbox). |
| Cc but no To | — | `AhaSend::MessageError`: AhaSend needs a To address alongside Cc. |
| More than 100 recipients on `/messages`, or more than 50 To + Cc + Bcc on a conversation | — | `AhaSend::MessageError`, before anything is sent. Split the send into batches. |
| Substitutions plus Cc or Bcc | — | `AhaSend::MessageError`: the conversation endpoint does not render substitutions, so the template would go out with its `{{ }}` placeholders. Send substitutions without Cc/Bcc. |

- `from`, `reply_to`, `subject`, text/HTML/AMP parts and attachments are
  mapped directly.
- Inline images (`attachments.inline[...]`, referenced from the HTML with
  `attachments["logo.png"].url`) are sent with their MIME Content-ID in angle
  brackets, which is what makes them render inline.
- AhaSend assigns the `Message-ID`; after delivery it is available as
  `message.message_id`.

## Delivery results and errors

`deliver_now` / `deliver!` return as usual. The delivery method itself returns
an `AhaSend::DeliveryResult` with one entry per recipient:

```ruby
result = AhaSend::DeliveryMethod.new(settings).deliver!(mail)
result.id         # => "<4f1e...@ahasend.com>"
result.status     # => "queued" (or "scheduled")
result.replayed?  # => true when the API answered from its idempotency store
result.messages   # => [#<struct id:, status:, recipient:, error:, schedule:>, ...]
result.partial?   # => true when some recipients were accepted and others rejected
result.failed     # => the rejected entries (see Partial delivery below)
```

Errors are typed, so you can rescue what you care about:

| Error | When |
| --- | --- |
| `AhaSend::ConfigurationError` | A setting is missing, invalid or unknown |
| `AhaSend::MessageError` | The message cannot be sent as built (see above, including the recipient limits); raised before any request |
| `AhaSend::ValidationError` | 400: the API rejected the request (`error.body` has its message) |
| `AhaSend::AuthenticationError` | 401: the API key is missing or invalid |
| `AhaSend::ForbiddenError` | 403: the key cannot send from this domain, the account cannot send, or sending from the domain is paused |
| `AhaSend::IdempotencyError` | 409: a request with the same Idempotency-Key is still in progress, after retries (`error.in_progress?`, `error.retry_after`); or 422: the key was already used for a different request |
| `AhaSend::RateLimitError` | 429 after retries are exhausted (`error.retry_after`) |
| `AhaSend::ServerError` | 5xx after retries are exhausted |
| `AhaSend::ConnectionError` | No HTTP response (timeout, DNS, TLS); the cause is in `error.cause` |
| `AhaSend::UnexpectedResponseError` | A 2xx response that is not the documented message list. **Delivery state unknown**: the email may have gone out |
| `AhaSend::DeliveryError` | The API rejected **every** recipient (`status: "error"` for each, e.g. a 553 for a blocked recipient domain); nothing was sent. `error.result` has the per-recipient errors |

All of them inherit from `AhaSend::Error`. With ActionMailer's default
`raise_delivery_errors = true` they propagate out of `deliver_now` (and fail the
job for `deliver_later`).

### Partial delivery

The API can accept some recipients of a message and reject others in the same
response. That is **not** raised: the accepted recipients are already being
sent, and a failed `deliver_later` job would be retried with a new
Idempotency-Key, sending them a second copy. The rejected recipients are
reported instead, in `result.failed` (with `result.partial?`) and in the
`deliver.ahasend` notification's `:failed_recipients` (see
[Monitoring](#monitoring)).

`AhaSend::DeliveryError` is raised only when every recipient was rejected, so
retrying it cannot duplicate anything. A permanent rejection will fail again on
every retry, though; to stop retrying it, handle it in your mailer
(`ActionMailer::MailDeliveryJob` passes job exceptions to the mailer's
`rescue_from`):

```ruby
class ApplicationMailer < ActionMailer::Base
  rescue_from AhaSend::DeliveryError do |error|
    Rails.logger.warn("AhaSend rejected all recipients: #{error.message}")
  end
end
```

## Retries and idempotency

Every request carries an `Idempotency-Key`. If you don't set one, the gem
generates a UUID per delivery. Because of that, retrying is safe: a request
the API already completed is answered from its store instead of sending the
email again.

The client retries 429, 500, 502, 503, 504, network failures, and a 409 that
says a request with the same key is still in progress. It always resends the
same key and the same body, waits for the API's `Retry-After` when present
(capped at 30 s) and otherwise backs off exponentially with jitter
(0.5 s, 1 s, 2 s, ... capped at 8 s). `max_retries: 0` turns this off.
Other client errors (400, 401, 403, 422, ...) are never retried.

Set your own key when you want *your* retries to be safe too, for example
when a background job may run twice:

```ruby
headers["AhaSend-Idempotency-Key"] = "order-confirmation-#{order.id}"
```

The API accepts a key again only for a byte-identical request, and a retried
job rebuilds the message. Keep the rebuilt message identical: in particular,
give inline images a fixed Content-ID, because otherwise Mail generates a
random one each time (in the attachment and in the HTML that references it)
and the API rejects the rebuilt request with `AhaSend::IdempotencyError` (422):

```ruby
attachments.inline["logo.png"] = {
  content: File.binread(Rails.root.join("app/assets/images/logo.png")),
  content_id: "<logo.png@yourapp.example>"
}
# in the view: image_tag attachments["logo.png"].url
```

## Monitoring

Rails logs each delivery in its `deliver.action_mailer` notification with the
Message-ID Mail generated *before* sending. AhaSend then assigns its own. To
connect the two, the gem emits a `deliver.ahasend` notification around every
API call:

```ruby
ActiveSupport::Notifications.subscribe("deliver.ahasend") do |event|
  event.payload[:mail_message_id]   # the ID in Rails' deliver.action_mailer event
  event.payload[:message_ids]       # AhaSend's Message-IDs, one per recipient
  event.payload[:recipients]        # [{ email:, status:, id:, error: }, ...]
  event.payload[:failed_recipients] # emails the API rejected, e.g. in a partial delivery
  event.payload[:replayed]          # true when answered from the idempotency store
  event.payload[:endpoint]          # :messages or :conversation
  event.payload[:sandbox]           # true for sandbox sends
end
```

The payload never contains credentials or message content. When delivery
fails, ActiveSupport adds the exception under `:exception`. Without
ActiveSupport (plain Ruby), no event is emitted.

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

The suite checks payloads against a request contract generated from
AhaSend's OpenAPI spec (`spec/fixtures/api`, with its source recorded), and
runs the Rails delivery lifecycle (deliver_later, interceptors, observers,
`perform_deliveries`, `raise_delivery_errors`, `delivery_method_options`) in a
real Rails app booted in a separate process. CI covers each Rails minor from
7.0 to 8.1, the oldest supported `mail` (2.7), and plain Ruby with no Rails
installed.

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
