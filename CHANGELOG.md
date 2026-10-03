# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-03

### Added

- `AhaSend::DeliveryMethod`: ActionMailer / Mail delivery method that sends
  through the AhaSend v2 HTTP API (`delivery_method = :ahasend`).
- Automatic endpoint selection: `/messages` for plain sends, `/messages/conversation`
  when the message has Cc or Bcc recipients.
- Attachments and inline (CID) images, custom headers, text/HTML/AMP bodies.
- Per-message options via `AhaSend-*` headers or `message.ahasend`: tags,
  tracking, substitutions, retention, schedule, sandbox, sandbox_result,
  idempotency_key. Settings-level defaults for the same options.
- `AhaSend::Client`: automatic `Idempotency-Key`, retries with `Retry-After` /
  jittered exponential backoff on 429, 5xx and network errors, typed errors
  (`ValidationError`, `AuthenticationError`, `RateLimitError`, `ServerError`, ...).
- `AhaSend::DeliveryResult` with per-recipient status; `DeliveryError` when the
  API rejects a recipient. AhaSend's Message-ID is written back to the mail.
- Railtie registering the delivery method and `config.action_mailer.ahasend_settings`.
- Supported: Ruby 3.1+, Rails 7.0–8.x (and the plain `mail` gem).

[Unreleased]: https://github.com/Sameer1122/ahasend-rails/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Sameer1122/ahasend-rails/releases/tag/v0.1.0
