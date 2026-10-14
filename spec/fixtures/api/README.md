# API fixtures

Request and response shapes for the AhaSend v2 send endpoints, taken from
AhaSend's published OpenAPI spec so the tests check the gem against the API
contract rather than against its own assumptions.

- Spec: <https://github.com/AhaSend/docs/blob/3add235/openapi.yaml>
  (commit `3add235`, "Docs: copy the API spec from the server", 2026-10-11).
- Each response fixture names the spec section it comes from in `source`.
  The spec has no example 202 bodies, so those are built from the
  `CreateMessageResponse` / `CreateSingleMessageResponse` schemas.
- `request_contract.json` is generated from `components.schemas` (allowed
  and required properties, array limits, and the Content-ID bracket rule).
  Regenerate it when the API spec changes.

Fake HTTP cannot show whether the server accepts a payload, renders
substitutions, or displays an inline image. `bin/live_check` covers server
acceptance in sandbox mode; inline rendering needs a delivered message.
