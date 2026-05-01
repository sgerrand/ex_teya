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

Elixir client library for the [Teya Online Payments API](https://docs.teya.com/apis/online-payments/apis) and the [Teya POSLink API](https://docs.teya.com/apis/poslink/openapi.yaml), published as the `teya` Hex package. Targets Elixir `~> 1.17`.

**Runtime dependencies:** `req` (HTTP + test stubs), `jason` (JSON).
**Dev/test dependencies:** `ex_doc`, `plug` (required by `Req.Test` stubs).

**Linting:** Credo (`~> 1.7`) is configured and runs on pre-push via lefthook (`mix credo --strict`). No Dialyzer. `mix format` is also enforced.

## Architecture

The library is an OTP application (`Teya.Application`) that starts a `Task.Supervisor` (always) and a `Teya.Auth` GenServer (only when `:client_id` is configured). Auth fetches and caches OAuth 2.0 tokens (client credentials grant) and refreshes them proactively before expiry.

```text
lib/teya/
  application.ex      — starts Teya.TaskSupervisor (always) and Teya.Auth (if :client_id set)
  config.ex           — %Teya.Config{} struct + Config.from_env/0
  error.ex            — %Teya.Error{code, message, status} returned on failures
  auth.ex             — GenServer: lazy token fetch, cache, proactive refresh
  client.ex           — HTTP layer: calls Auth.token/0, adds Bearer header,
                        auto-generates Idempotency-Key on POST/PATCH
  sse.ex              — SSE frame parser (parse/1) + shared stream helper (stream/7)
  checkout.ex         — POST/GET /v2/checkout/sessions
  transaction.ex      — POST/GET /v3/transactions/online
  pay_by_link.ex      — POST/GET/PATCH /v2/payment-links
  capture.ex          — POST /v1/transactions/{id}/capture
  refund.ex           — POST /v3/refunds
  receipt.ex          — POST /v1/transactions/{id}/receipts
  token.ex            — DELETE /v1/tokens/{id}
  poslink/
    store.ex          — GET /poslink/v1/stores, GET /poslink/v1/stores/{id}/terminals
    payment.ex        — POST/PATCH/GET /poslink/v2/payment-requests, GET /poslink/v1/payment-requests
                        subscribe/2: spawns a Task to stream SSE payment status events
    refund.ex         — POST /poslink/v1/refunds
    receipt.ex        — POST /poslink/v1/receipt-requests
                        subscribe_status/2: spawns a Task to stream SSE printer status events
```

### POSLink streaming (Approach 2: task + message-passing)

`Payment.subscribe/2` and `Receipt.subscribe_status/2` use
`Task.Supervisor.async_nolink(Teya.TaskSupervisor, ...)` to open an SSE
connection (`Req.get/2` with `into: :self`) and forward parsed events as
messages to the caller:

- `{:poslink_payment, id, event_type, data}` / `{:poslink_payment_error, id, reason}`
- `{:poslink_receipt, id, event_type, data}` / `{:poslink_receipt_error, id, reason}`

SSE bytes are parsed by `Teya.SSE.parse/1`, which accumulates a buffer across
chunks and emits complete events. `event_type` is `"full"` (complete snapshot)
or `"diff"` (partial update). `data` is a decoded JSON map.

## Testing

Tests use `Req.Test` to stub HTTP. Three separate stub names are used to cleanly separate concerns:

- `Teya.Auth` stub — handles token endpoint (`/connect/token`); set in `APICase` setup and `allow`-ed to the Auth GenServer process
- `Teya.Client` stub — handles API endpoint calls; set per-test via `stub_api/1`
- `Teya.POSLink.Subscriber` stub — handles POSLink SSE streaming requests; configured via `:sse_req_options` in test config

`Req.Test.stub` must always be called **before** `Req.Test.allow` — allow copies the current stub to a location accessible from the target process.

`Teya.APICase` in `test/support/api_case.ex` is the shared test case template for resource module tests. Use `stub_api/1`, `json_response/3`, and `error_response/4` helpers.

`Teya.POSLink.SubscribeCase` in `test/support/poslink_subscribe_case.ex` is the test case template for streaming (subscribe) tests. It pre-seeds the Auth GenServer with a valid token instead of resetting it to nil — this avoids a race condition where a `Task.Supervisor.async_nolink` task outlives the test process and triggers a stub-not-found crash in `Teya.Auth` when it tries to call `fetch_token`. Use `stub_sse/1`, `json_response/3`, and `error_response/4` helpers.

Auth state is reset between auth tests using `:sys.replace_state/2` on the running `Teya.Auth` GenServer.

`Task.Supervisor.async_nolink` propagates `$callers` to spawned tasks, so `Req.Test` stubs set in the test process are automatically accessible from the task without explicit `allow` calls.

### Auth failure and retry behaviour

`Teya.Auth` refreshes tokens proactively `@refresh_margin_seconds` (30s) before
expiry. If `fetch_token` fails during a proactive background refresh
(`handle_info(:refresh, state)`), the GenServer schedules a retry after 10
seconds — it does **not** crash. The cached token remains valid until it
expires; only after expiry will `Auth.token/0` return `{:error, reason}`.

If `fetch_token` fails during a synchronous `Auth.token/0` call (e.g. on first
use when no token is cached), the call returns `{:error, reason}` immediately
and no token is cached.

## Documentation conventions

`Teya.Auth` is an internal module (`@moduledoc false`) and must stay hidden from
public docs. Do not reference it with backtick module syntax (`` `Teya.Auth` ``)
in README.md or any other file processed by ExDoc — use plain prose instead
(e.g. "the auth process"). ExDoc treats backtick-quoted module names as links
and will warn (or error with `--warnings-as-errors`) when the target is hidden.

## API versioning

Endpoint versions are mixed (v1/v2/v3) and differ per resource — do not assume a uniform version across all paths. See individual resource modules for the exact paths.
