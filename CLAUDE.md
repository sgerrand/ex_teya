# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
mix deps.get          # fetch dependencies
mix compile           # build
mix test              # run full test suite
mix test test/teya/checkout_test.exs   # run a single test file
mix coveralls         # run tests with coverage; fails below 100%
mix coveralls.html    # same, plus an HTML report in /cover/
mix format            # format code
mix docs              # generate ExDoc documentation
```

## Project context

Elixir client library for the [Teya Online Payments API](https://docs.teya.com/apis/online-payments/apis) and the [Teya POSLink API](https://docs.teya.com/apis/poslink/openapi.yaml), published as the `teya` Hex package. Targets Elixir `~> 1.17`.

**Runtime dependencies:** `req` (HTTP + test stubs), `jason` (JSON), and OTP's
`:public_key` (webhook signatures), listed in `extra_applications`.
**Dev/test dependencies:** `ex_doc`, `plug` (required by `Req.Test` stubs).

**Linting:** Credo (`~> 1.7`) is configured and runs on pre-push via lefthook (`mix credo --strict`). No Dialyzer. `mix format` is also enforced.

## Architecture

The library is an OTP application (`Teya.Application`) that starts a `Task.Supervisor` (always) and a `Teya.Auth` GenServer (only when `:client_id` is configured). Auth fetches and caches OAuth 2.0 tokens (client credentials grant) and refreshes them proactively before expiry.

```text
lib/teya/
  application.ex      — starts Teya.TaskSupervisor (always) and Teya.Auth (if :client_id set)
  config.ex           — %Teya.Config{} struct + Config.from_env/0
  error.ex            — %Teya.Error{code, message, status, invalid_parameters} returned
                        on failures, including token endpoint (OAuth) failures
  auth.ex             — GenServer: token cache and proactive refresh; fetches
                        run in tasks, and waiting callers share one fetch
  client.ex           — HTTP layer: calls Auth.token/0, adds Bearer header,
                        auto-generates Idempotency-Key on POST/PATCH
  http.ex             — shared by every module that makes a request: the user
                        agent, and each request kind's options with their
                        fallback to :req_options
  sse.ex              — SSE helpers: stream/6 sends each event to a process,
                        first/4 returns the first event of a given name;
                        frames are decoded by the req_server_sent_events plugin
  checkout.ex         — POST/GET /v2/checkout/sessions
  transaction.ex      — POST/GET /v3/transactions/online
  pay_by_link.ex      — POST/GET/PATCH /v2/payment-links
  capture.ex          — POST /v1/transactions/{id}/capture
  refund.ex           — POST /v3/refunds
  receipt.ex          — POST /v1/transactions/{id}/receipts
  token.ex            — DELETE /v1/tokens/{id}
  moto.ex             — POST /v1/transactions/moto
  webhook.ex          — verifies the x-teya-signature on an incoming webhook
                        (SHA256withRSA over the raw body); no HTTP of its own
  poslink/
    store.ex          — GET /poslink/v1/stores, GET /poslink/v1/stores/{id}/terminals,
                        GET /poslink/v1/stores/{id}/terminals/{tid}/configs,
                        PUT /poslink/v1/stores/{id}/configs/{key}
    epos.ex           — POST /poslink/v1/epos/register; takes a user's token
                        (Client's :token option), not the auth process's
    payment.ex        — POST /poslink/v3/payment-requests, GET /poslink/v3/payment-requests/{id} (SSE),
                        PATCH /poslink/v2/payment-requests/{id}, GET /poslink/v2/payment-requests,
                        GET /poslink/v3/payment-requests/{id}/receipt-text
                        subscribe/2: spawns a Task to stream SSE payment status events
    refund.ex         — POST /poslink/v2/refunds
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

SSE bytes are decoded by the `req_server_sent_events` plugin, which both
`Teya.SSE.stream/6` and `Teya.SSE.first/4` attach. They read their request
options from `:sse_req_options`, falling back to `:req_options`. `event_type` is `"full"` (complete snapshot) or
`"diff"` (partial update), and is `nil` for a frame with no event line. `data`
is a decoded JSON map.

`Payment.get/2` does not use messages. It runs `Teya.SSE.first/4` in a task of
its own, whose `into:` handler halts on the first `"full"` event and hands the
data back as the task's result. Nothing reaches the caller's mailbox, so it
cannot mix with a `subscribe/2` stream for the same payment.

## Testing

Tests use `Req.Test` to stub HTTP. Three separate stub names are used to cleanly separate concerns:

- `Teya.Auth` stub — handles token endpoint (`/connect/token`); set in `APICase` setup and `allow`-ed to the Auth GenServer process
- `Teya.Client` stub — handles API endpoint calls; set per-test via `stub_api/1`
- `Teya.POSLink.Subscriber` stub — handles POSLink SSE streaming requests; configured via `:sse_req_options` in test config

`Req.Test.stub` must always be called **before** `Req.Test.allow` — allow copies the current stub to a location accessible from the target process.

`Teya.APICase` in `test/support/api_case.ex` is the shared test case template for resource module tests. Use `stub_api/1`, `json_response/3`, and `error_response/4` helpers.

`Teya.POSLink.SubscribeCase` in `test/support/poslink_subscribe_case.ex` is the test case template for streaming (subscribe) tests. It pre-seeds the Auth GenServer with a valid token instead of resetting it to nil — this avoids a race condition where a `Task.Supervisor.async_nolink` task outlives the test process and triggers a stub-not-found crash in `Teya.Auth` when it tries to call `fetch_token`. Use `stub_sse/1`, `json_response/3`, and `error_response/4` helpers.

Auth state is reset between auth tests using `:sys.replace_state/2` on the running `Teya.Auth` GenServer.

### Coverage

Coverage is measured by ExCoveralls and must stay at 100%. Settings live in
`coveralls.json`: `test/support/` is skipped, and `minimum_coverage` is 100.
They cannot move into `mix.exs` — ExCoveralls reads only `:tool` and
`:test_task` from the `test_coverage` project option, and takes everything
else from JSON.

Only the local, HTML and Cobertura reporters check that threshold. The lcov
reporter (used in CI to produce the file uploaded to Coveralls) does not, so CI
runs `mix coveralls` as a separate step to fail the build on a coverage drop.
The same command runs on pre-push via lefthook.

`Task.Supervisor.async_nolink` propagates `$callers` to spawned tasks, so `Req.Test` stubs set in the test process are automatically accessible from the task without explicit `allow` calls. `Task.start/1` does too; plain `spawn/1` does not.

`Req.Test` delivers the whole response only once the stub plug returns, even
for `Plug.Conn.send_chunked/2` plus `Plug.Conn.chunk/2`. A stubbed SSE stream
therefore cannot stay open while the test inspects state: every event arrives
at once, and the stream task always ends on its own. Behaviour that depends on
a still-open stream — such as `Teya.SSE.first/4` stopping the read once it has
the event — cannot be observed through a stub. What can be observed is which
event it returns, so test that instead: two `"full"` events, and the first one
must win.

### Auth failure and retry behaviour

`Teya.Auth` refreshes tokens in the background `@refresh_margin_seconds` (30s)
before expiry, or halfway through the life of a token that lives less than a
minute. A token that lives a second or less gets no background refresh; a new
one is fetched when the next caller needs it.

If a background refresh (`handle_info(:refresh, state)`) fails, the GenServer
retries after 1 second, doubling each time up to 1 minute — it does **not**
crash. `Auth.token/0` keeps returning the cached token, even while refreshes
fail, until 5 seconds before it expires, and only then fetches synchronously.
The gap keeps a request from reaching Teya with a token that has just run out.

If that synchronous fetch fails (for example on first use, when no token is
cached), the call returns `{:error, reason}` and nothing is cached. For the
next second, callers are given that same failure rather than each sending
another request. A caller waits at most `:token_timeout_ms` (15s) for a token,
then gets `{:error, %Teya.Error{}}`.

Every fetch, the background refresh included, runs in a task under
`Teya.TaskSupervisor`, never inside the GenServer. A caller with a usable token
cached is answered at once, whatever a fetch is doing. Callers who need a new
token join a list of waiters, each with the time it gives up, and the one fetch
under way answers them all with `GenServer.reply/2`. Each new caller clears out
waiters that have given up, so the list holds only callers still waiting. There is only ever one fetch at a time. A fetch that
runs a second past `:token_timeout_ms` (or 60s when that is `:infinity`) is
killed and
reported as a failure, so one that hangs cannot hold every later caller. The
task catches its own errors, so no crash report — which could carry the
request and the client secret — is logged. A token that lives 5 seconds or
less is given to the callers who waited for it and never cached.

`Auth.token/0` returns `{:error, %Teya.Error{}}` for any exit from the call, not
only a timeout, including when no `:client_id` is configured and so the auth
process is not running.

In tests, a fetch finishes after the call that started it returns, so a test
that sends `:refresh` must wait for the fetch to settle before reading the
state (see `refresh/1` in `auth_test.exs`). Test setup that resets the auth
state must also reset `fetch` and `waiters`, or a fetch left from an earlier
test makes callers wait on a task that is not theirs.

## Documentation conventions

`Teya.Auth` is an internal module (`@moduledoc false`) and must stay hidden from
public docs. Do not wrap it in backticks in README.md or any other file
processed by ExDoc — use plain prose instead (e.g. "the auth process"). ExDoc
treats backtick-quoted module names as links and will warn (or error with
`--warnings-as-errors`) when the target is hidden.

## API versioning

Endpoint versions are mixed (v1/v2/v3) and differ per resource — do not assume a uniform version across all paths. See individual resource modules for the exact paths.
