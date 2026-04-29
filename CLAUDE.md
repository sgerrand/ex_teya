# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
mix deps.get          # fetch dependencies
mix compile           # build
mix test              # run full test suite
mix test test/teya/checkout_test.exs   # run a single test file
mix test --cover      # run tests with coverage (output → /cover/)
mix format            # format code
mix docs              # generate ExDoc documentation
```

## Project context

Elixir client library for the [Teya Online Payments API](https://docs.teya.com/apis/online-payments/apis), published as the `teya` Hex package. Targets Elixir `~> 1.19`.

**Runtime dependencies:** `req` (HTTP + test stubs), `jason` (JSON).
**Dev/test dependencies:** `ex_doc`, `plug` (required by `Req.Test` stubs).

No linter configured (no Credo, no Dialyzer). Only quality tooling in place is `mix format`.

## Architecture

The library is an OTP application (`Teya.Application`) that starts a supervised `Teya.Auth` GenServer. Auth fetches and caches OAuth 2.0 tokens (client credentials grant) and refreshes them proactively before expiry.

```text
lib/teya/
  application.ex   — starts Teya.Auth; only if :client_id is configured
  config.ex        — %Teya.Config{} struct + Config.from_env/0
  error.ex         — %Teya.Error{code, message, status} returned on failures
  auth.ex          — GenServer: lazy token fetch, cache, proactive refresh
  client.ex        — HTTP layer: calls Auth.token/0, adds Bearer header,
                     auto-generates Idempotency-Key on POST/PATCH
  checkout.ex      — POST/GET /v2/checkout/sessions
  transaction.ex   — POST/GET /v3/transactions/online
  pay_by_link.ex   — POST/GET/PATCH /v2/payment-links
  capture.ex       — POST /v1/transactions/{id}/capture
  refund.ex        — POST /v3/refunds
  receipt.ex       — POST /v1/transactions/{id}/receipts
  token.ex         — DELETE /v1/tokens/{id}
```

## Testing

Tests use `Req.Test` to stub HTTP. Two separate stub names are used to cleanly separate concerns:

- `Teya.Auth` stub — handles token endpoint (`/connect/token`); set in `APICase` setup and `allow`-ed to the Auth GenServer process
- `Teya.Client` stub — handles API endpoint calls; set per-test via `stub_api/1`

`Req.Test.stub` must always be called **before** `Req.Test.allow` — allow copies the current stub to a location accessible from the target process.

`Teya.APICase` in `test/support/api_case.ex` is the shared test case template for resource module tests. Use `stub_api/1`, `json_response/3`, and `error_response/4` helpers.

Auth state is reset between auth tests using `:sys.replace_state/2` on the running `Teya.Auth` GenServer.

## API versioning

Endpoint versions are mixed (v1/v2/v3) and differ per resource — do not assume a uniform version across all paths. See individual resource modules for the exact paths.
