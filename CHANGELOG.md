# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

First release (0.1.0).

### Added

- `AhaSend::DeliveryMethod`: ActionMailer / Mail delivery method that sends
  through the AhaSend v2 HTTP API (`delivery_method = :ahasend`), with a
  Railtie registering it and `config.action_mailer.ahasend_settings`.
- Endpoint selection: `/messages` for To-only and Bcc-only mail (one copy per
  recipient), `/messages/conversation` for To with Cc/Bcc. An explicit
  `smtp_envelope_to` (e.g. from a redirecting interceptor) is honoured: mail is
  sent only to the envelope addresses.
- Attachments and inline images (Content-ID sent in angle brackets, as the API
  requires), custom headers, text/HTML/AMP bodies.
- Per-message options via `AhaSend-*` headers (AhaSend's SMTP header names
  where SMTP has one) or `message.ahasend`: tags, tracking, retention, sandbox,
  sandbox_result, substitutions, schedule, idempotency_key; settings-level
  defaults for all but the idempotency key. Nested options merge field by field.
- Validation with clear errors: `ConfigurationError` for settings (checked on
  first send, not at boot), `MessageError` for malformed or unknown option
  headers/values and for messages the API cannot represent (Cc without To,
  substitutions with Cc/Bcc, more than 100 recipients or 50 To+Cc+Bcc).
- `AhaSend::Client`: automatic `Idempotency-Key`; retries with `Retry-After` or
  jittered exponential backoff on 429, 5xx, network errors and in-progress
  idempotent requests (409), reusing the same key and body; typed errors
  following the API v2 contract (`ValidationError`, `AuthenticationError`,
  `ForbiddenError`, `IdempotencyError`, `RateLimitError`, `ServerError`, ...).
- `AhaSend::DeliveryResult` with per-recipient status and `replayed?`;
  responses are validated against the documented shape
  (`UnexpectedResponseError` otherwise). A partial delivery (some recipients
  rejected) returns normally and reports the rejections, so a retried job
  cannot send duplicates; `DeliveryError` only when every recipient is
  rejected. AhaSend's Message-ID is written back to the mail.
- `deliver.ahasend` ActiveSupport notification linking Rails' Message-ID to
  AhaSend's IDs, per-recipient statuses and rejected recipients.
- Supported: Ruby 3.1+, Rails 7.0–8.1, and the plain `mail` gem (2.7+) without Rails.

[Unreleased]: https://github.com/AhaSend/ahasend-rails/commits/main
