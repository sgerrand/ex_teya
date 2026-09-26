# Teya

[![Test Status](https://github.com/sgerrand/ex_teya/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sgerrand/ex_teya/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/github/sgerrand/ex_teya/badge.svg?branch=main)](https://coveralls.io/github/sgerrand/ex_teya?branch=main)
[![Hex Version](https://img.shields.io/hexpm/v/teya.svg)](https://hex.pm/packages/teya)
[![Hex Docs](https://img.shields.io/badge/docs-hexpm-blue.svg)](https://hexdocs.pm/teya/)

Elixir client for the [Teya API](https://docs.teya.com/apis/overview).

## Installation

Add `teya` to your dependencies in `mix.exs`:

<!-- x-release-please-start-version -->

```elixir
def deps do
  [
    {:teya, "~> 0.4.3"}
  ]
end
```

<!-- x-release-please-end -->

## Configuration

```elixir
# config/runtime.exs
config :teya,
  client_id: System.fetch_env!("TEYA_CLIENT_ID"),
  client_secret: System.fetch_env!("TEYA_CLIENT_SECRET"),
  token_url: "https://identity.teya.com/connect/token",
  base_url: "https://api.teya.com",
  scopes: [
    # list only the scopes your application needs — see table below
  ]
```

OAuth tokens are fetched automatically and refreshed before expiry. Only request the scopes your application needs.

These settings are optional:

| Setting | Default | What it does |
|---|---|---|
| `:token_timeout_ms` | `15_000` | How long a request waits for an access token before it returns an error, or `:infinity`. A token request still running then carries on, and caches its token for the next request |
| `:sse_stream_timeout_ms` | `60_000` | How long a POSLink stream waits for the next event before it gives up |
| `:sse_max_error_body_bytes` | `65_536` | How much of a failed stream's error body is kept. A JSON error larger than this is cut and can no longer be read, so the error keeps its status and raw text but no code |

### Scope reference

| Scope | Library function |
| --- | --- |
| `checkout/sessions/create` | `Teya.Checkout.create_session/2` |
| `checkout/sessions/id/get` | `Teya.Checkout.get_session/1` |
| `payment-links/create` | `Teya.PayByLink.create/2` |
| `payment-links/id/get` | `Teya.PayByLink.get/1` |
| `payment-links/id/update` | `Teya.PayByLink.update/2` |
| `transactions/online/create` | `Teya.Transaction.create/2` |
| `transactions/online/id/get` | `Teya.Transaction.get/1` |
| `captures/create` | `Teya.Capture.create/3` |
| `refunds/create` | `Teya.Refund.create/2` |
| `transactions/card-present/create` | `Teya.CardPresent.create/2` |
| `reversals/create` | `Teya.Reversal.create/2` |
| `transactions/id/receipts/create` | `Teya.Receipt.create/3` |
| `token/delete` | `Teya.Token.delete/3` |
| `poslink/stores/get` | `Teya.POSLink.Store.list/1` |
| `poslink/stores/id/terminals/get` | `Teya.POSLink.Store.list_terminals/2` |
| `poslink/payment-requests/create` | `Teya.POSLink.Payment.create/2` |
| `poslink/payment-requests/id/get` | `Teya.POSLink.Payment.subscribe/2`, `Teya.POSLink.Payment.get/2` |
| `poslink/payment-requests/id/update` | `Teya.POSLink.Payment.cancel/2` |
| `poslink/payment-requests/get` | `Teya.POSLink.Payment.list/1` |
| `poslink/refunds/create` | `Teya.POSLink.Refund.create/2` |
| `poslink/receipt-requests/create` | `Teya.POSLink.Receipt.create/2` |
| `poslink/receipt-requests/id/status/get` | `Teya.POSLink.Receipt.subscribe_status/2` |

Obtain credentials from the [Teya Developer Portal](https://docs.teya.com/apis/developer-portal/introduction).

## Usage

### Hosted Checkout

Redirect customers to a Teya-hosted payment page:

```elixir
params = %{
  "amount" => %{"currency" => "GBP", "value" => 1000},
  "type" => "SALE",
  "success_url" => "https://example.com/success",
  "failure_url" => "https://example.com/failure"
}

case Teya.Checkout.create_session(params) do
  {:ok, %{"session_url" => url}} ->
    # redirect the customer to url
  {:error, %Teya.Error{code: code, message: message}} ->
    # handle error
end
```

Poll for the result after the customer returns:

```elixir
{:ok, session} = Teya.Checkout.get_session(session_id)
session["payment_status"]  # "NONE" | "SUCCESS" | "FAILED"
session["session_status"]  # "ACTIVE" | "PROCESSING" | "COMPLETED" | "EXPIRED"
```

### Direct Card Processing (Embedded UI)

Process a card payment from your own payment form:

```elixir
params = %{
  "amount" => %{"currency" => "GBP", "value" => 1000},
  "type" => "SALE",
  "initiator" => "CUSTOMER",
  "store_id" => "your-store-uuid",
  "payment_method" => %{
    "type" => "CARD",
    "card" => %{
      "number" => "4111111111111111",
      "expiry_month" => "12",
      "expiry_year" => "2028",
      "cvc" => "123"
    }
  }
}

case Teya.Transaction.create(params) do
  {:ok, %{"type" => "ONLINE_TRANSACTION", "online_transaction" => txn}} ->
    txn["status"]  # "SUCCESS" | "FAILURE" | "PENDING"
  {:ok, %{"type" => "REDIRECT_TRANSACTION_RESPONSE"} = resp} ->
    # 3DS challenge required — redirect customer to:
    resp["redirect_transaction_response"]["redirect_url"]
  {:error, %Teya.Error{} = err} ->
    # handle error
end
```

### Pay By Link

Generate a shareable payment link:

```elixir
{:ok, %{"payment_link" => url}} =
  Teya.PayByLink.create(%{
    "amount" => %{"currency" => "GBP", "value" => 5000},
    "expires_at" => "2024-12-31T23:59:59Z"
  })
```

### Capture a Pre-authorisation

```elixir
:ok = Teya.Capture.create(transaction_id)
```

### Refund

```elixir
{:ok, _} = Teya.Refund.create(%{"transaction_id" => transaction_id})
```

### Webhooks

Teya signs every webhook it sends, and you should check the signature before
you trust the body. `Teya.Webhook.parse/3` takes only a key read by
`Teya.Webhook.decode_key/1`, so read it once, when your application starts. A
bad key then stops the application there rather than turning away every
webhook:

```elixir
# in MyApp.Application.start/2
{:ok, key} = Teya.Webhook.decode_key(System.fetch_env!("TEYA_WEBHOOK_KEY"))
:persistent_term.put(:teya_webhook_key, key)
```

Then check each webhook in its handler:

```elixir
require Logger

key = :persistent_term.get(:teya_webhook_key)
signature = conn |> Plug.Conn.get_req_header("x-teya-signature") |> List.first()

case Teya.Webhook.parse(conn.assigns[:raw_body], signature, key) do
  {:ok, %{"event" => "payment.succeeded.v1", "data" => data}} -> fulfil_order(data)
  {:ok, _other_event} -> :ok
  {:error, reason} -> Logger.warning("rejected a webhook: #{inspect(reason)}")
end
```

The signature covers the exact bytes Teya sent, so the body must be kept as
received. The `Teya.Webhook` docs show how to keep it, and cover retries and
replayed webhooks.

### Card-Present (Direct Terminal Integration)

Process a payment where your software supplies the raw card data from a POS
terminal (EMV TLV, encrypted track, PIN block). For Teya-managed terminals
accessed through ePOS middleware, see [POSLink](#poslink-card-present-terminals)
instead.

```elixir
params = %{
  "type"          => "SALE",
  "entry_mode"    => "CONTACT_EMV",
  "amounts"       => %{"amount" => 1000, "currency" => "GBP"},
  "emv_data"      => "9F2608AABBCCDD112233",
  "track_data"    => %{
    "encryption_key_id" => "key-1",
    "encrypted_track"   => "...",
    "encryption_ksn"    => "ksn-1"
  },
  "transacted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
}

{:ok, response} = Teya.CardPresent.create(params)
response["status"]  # "SUCCESS" | "FAILURE" | "PENDING"
```

### MOTO (Mail and Telephone Orders)

For a card taken over the phone or by post and entered in a virtual terminal.
The card details are sent encrypted with a key Teya provides; handling them at
all puts your software within PCI DSS scope.

```elixir
{:ok, %{"status" => "SUCCESS"}} =
  Teya.Moto.create(%{
    "type"          => "SALE",
    "amounts"       => %{"amount" => 2500, "currency" => "GBP"},
    "card_details"  => %{
      "encrypted_card_data" => ciphertext,
      "encryption_key_id"   => key_id,
      "encryption_ksn"      => ksn
    },
    "transacted_at" => "2026-09-25T10:30:00Z"
  })
```

### Reversal

Void a transaction before it settles with the card network. Use a refund
(`Teya.Refund`) for transactions that have already settled.

```elixir
# Reverse by transaction ID
{:ok, response} = Teya.Reversal.create(%{
  "reversal_reason" => "CARD_REVERSAL",
  "transaction_id"  => transaction_id
})

# Or by the idempotency key used when creating the original transaction
{:ok, response} = Teya.Reversal.create(%{
  "reversal_reason" => "COMMUNICATION_REVERSAL",
  "idempotency_key" => original_idempotency_key
})

response["status"]  # "SUCCESS" | "FAILURE" | "PENDING" | "ACKNOWLEDGED"
```

### Dynamic Currency Conversion (DCC)

Before a card-present transaction, check whether the cardholder's card is
eligible for DCC and retrieve a rate quote. No OAuth credentials are required
for this endpoint.

```elixir
case Teya.DCC.quote(%{
  "store_id"      => store_id,
  "card_first9"   => String.slice(card_number, 0, 9),
  "base_amount"   => 1000,
  "base_currency" => "GBP"
}) do
  {:ok, offer} ->
    # Offer the cardholder: pay offer["cardholder_amount"] offer["cardholder_currency"]
    # If accepted, include the quote in the card-present transaction:
    dcc_params = %{
      "quoted_at"         => offer["quoted_at"],
      "cardholder_amount" => %{
        "amount"   => offer["cardholder_amount"],
        "currency" => offer["cardholder_currency"]
      }
    }
    Teya.CardPresent.create(Map.put(card_present_params, "dcc", dcc_params))

  {:error, %Teya.Error{code: code}} when code in ["NON_ELIGIBLE_CARD", "SAME_CURRENCY"] ->
    # Card not eligible — proceed without DCC
    Teya.CardPresent.create(card_present_params)
end
```

### POSLink (Card-Present Terminals)

POSLink integrates ePOS software with physical payment terminals. Discover
available stores and terminals, then create payment requests and stream their
status in real time.

#### Register an ePOS application

Registering once per store turns a signed-in user's token into credentials for
the library. It is a setup step: store the `client_id`, `client_secret` and
`scopes` that come back in your configuration, then restart the application,
which reads them only when it starts. Registering needs no `:client_id` of
its own.

```elixir
{:ok, %{"client_id" => id, "client_secret" => secret, "scopes" => scopes}} =
  Teya.POSLink.Epos.register(
    %{"store_id" => store_id, "epos_external_id" => "till-1"},
    user_token: user_jwt
  )
```

The client secret is a credential: store it as you would a password.

#### Discover stores and terminals

```elixir
{:ok, %{"stores" => stores}} = Teya.POSLink.Store.list()

store_id = hd(stores)["store_id"]
{:ok, %{"terminals" => terminals}} = Teya.POSLink.Store.list_terminals(store_id)

terminal_id = hd(terminals)["terminal_id"]
```

A store's settings apply to all its terminals. Read them for one terminal, or
change one for the whole store:

```elixir
{:ok, %{"configs" => configs}} = Teya.POSLink.Store.terminal_configs(store_id, terminal_id)
{:ok, _} = Teya.POSLink.Store.put_config(store_id, "PAT_ENABLED", "true")
```

#### Take a card-present payment

Create a payment request and subscribe to real-time status updates via SSE.
Events arrive as messages to the calling process:

```elixir
params = %{
  "store_id"           => store_id,
  "terminal_id"        => terminal_id,
  "requested_amount"   => %{"amount" => 1000, "currency" => "GBP"},
  "transaction_type"   => "SALE",
  "merchant_reference" => "order-1234"
}

{:ok, %{"payment_request_id" => id}} = Teya.POSLink.Payment.create(params)
{:ok, _task} = Teya.POSLink.Payment.subscribe(id, self())

receive do
  {:poslink_payment, ^id, "full", %{"status" => "SUCCESSFUL"} = data} ->
    # payment complete — data contains full transaction metadata
  {:poslink_payment, ^id, _type, %{"status" => "FAILED"}} ->
    # card declined or terminal error
  {:poslink_payment, ^id, _type, %{"status" => status}} when status in ["NEW", "IN_PROGRESS"] ->
    # intermediate state — keep waiting
  {:poslink_payment_error, ^id, reason} ->
    # connection or auth failure
end
```

`subscribe/2` returns immediately; the task runs under `Teya.TaskSupervisor`
and sends messages until the server closes the stream. The second argument is
the recipient pid and defaults to `self()`.

> **Task lifecycle:** The spawned task is not linked to the caller and is not
> restarted by the supervisor. If the SSE stream drops mid-payment (network
> error, server restart), the task sends `{:poslink_payment_error, id, reason}`
> and exits — there is no automatic reconnection. To recover, call
> `Teya.POSLink.Payment.get/2` to fetch the current status, or call
> `subscribe/2` again with the same `payment_request_id`.

#### Cancel a payment

```elixir
{:ok, _} = Teya.POSLink.Payment.cancel(payment_request_id)
```

#### POSLink refunds

```elixir
{:ok, _} = Teya.POSLink.Refund.create(%{
  "transaction_id" => gateway_payment_id,
  "amount"         => 1500
})
```

`transaction_id` must be the `gateway_payment_id` of the original payment. It
arrives on the payment's status stream when the payment completes. Do not send
the payment's own `transaction_id` — it is a different identifier and the
refund fails with `404 TRANSACTION_NOT_FOUND`.

#### Print a receipt

Submit a receipt print job and stream its printer status:

```elixir
{:ok, %{"receipt_id" => receipt_id}} =
  Teya.POSLink.Receipt.create(%{
    "store_id"    => store_id,
    "terminal_id" => terminal_id,
    "content"     => %{"type" => "JSON", "data" => %{"total" => "£10.00"}}
  })

{:ok, _task} = Teya.POSLink.Receipt.subscribe_status(receipt_id, self())

receive do
  {:poslink_receipt, ^receipt_id, _type, %{"status" => "PRINTED"}} -> :ok
  {:poslink_receipt, ^receipt_id, _type, %{"status" => "FAILED"}}  -> handle_failure()
  {:poslink_receipt_error, ^receipt_id, reason}                    -> handle_error(reason)
end
```

#### Receipt text

A successful payment or refund has a plain-text receipt, ready to print or
send:

```elixir
{:ok, %{"receipt_text" => text}} = Teya.POSLink.Payment.receipt_text(payment_request_id)
```

### Idempotency Keys

POST and PATCH requests automatically include a random `Idempotency-Key` header. Supply your own to safely retry a request:

```elixir
Teya.Checkout.create_session(params, idempotency_key: order_id)
```

### Error Handling

All functions return `{:ok, body}` or `{:error, %Teya.Error{}}`:

```elixir
case Teya.Checkout.create_session(params) do
  {:ok, response} -> response
  {:error, %Teya.Error{code: "TOO_MANY_REQUESTS"}} -> {:error, :rate_limited}
  {:error, %Teya.Error{code: "UNAUTHORISED"}} -> {:error, :unauthorized}
  {:error, %Teya.Error{status: status}} -> {:error, status}
end
```

When the API says which request fields it rejected, they are kept in
`invalid_parameters`:

```elixir
{:error, %Teya.Error{code: "BAD_REQUEST", invalid_parameters: params}} =
  Teya.Checkout.create_session(bad_params)

# [%{"name" => "amount", "reason" => "must be positive"}]
```

Token endpoint failures use the OAuth 2.0 error format, so `code` holds values
such as `"invalid_client"` and `"invalid_scope"`.

Ids that go into the request path, such as a session or payment request id,
are URL-encoded, so a `/` or `?` in one cannot reach a different endpoint.
Such an id that is `nil`, empty, `"."`, `".."`, or anything but text or an
integer raises `ArgumentError` before any request is sent: that is a mistake
in the calling code, not something the API said. Ids sent as query
parameters, such as the `store_id` for `Teya.Token.delete/3`, are encoded as
query values and not checked this way. The subscribe functions raise it too, in your process, not in the
task they start.

### User agent

Every request sends `User-Agent: teya-elixir/<version>`, which Teya recommends
so they can identify your integration. To send your own, use Req's
`:user_agent` option, or a `user-agent` header:

```elixir
config :teya, req_options: [user_agent: "acme-shop/1.0"]
```

Other headers and options you set there are used too, with three exceptions
the library always sets itself. API calls always send the library's own
bearer token, so an `:auth` option there is ignored. API calls carry their own
`Idempotency-Key`, since one key shared by every request would make each POST
look like a retry of the first. Token requests are always sent as a form,
whatever content type is set.

Token requests and SSE streams use `:auth_req_options` and `:sse_req_options`
when you set them, and `:req_options` when you do not. DCC quotes use only
`:dcc_req_options`: the endpoint takes no token, so the options for
authenticated API calls do not apply to it.

## Troubleshooting

### Rate limiting (`TOO_MANY_REQUESTS`)

Teya returns HTTP 429 when you exceed the rate limit. Back off exponentially
and retry using the same idempotency key to avoid duplicate operations:

```elixir
case Teya.POSLink.Payment.create(params, idempotency_key: ref) do
  {:error, %Teya.Error{code: "TOO_MANY_REQUESTS"}} ->
    Process.sleep(1_000)
    Teya.POSLink.Payment.create(params, idempotency_key: ref)
  result ->
    result
end
```

### 3DS redirect flow

When `Teya.Transaction.create/2` returns
`{:ok, %{"type" => "REDIRECT_TRANSACTION_RESPONSE"}}`, the cardholder must
complete a 3DS challenge before the payment is authorised. Redirect them to
`resp["redirect_transaction_response"]["redirect_url"]` and poll
`Teya.Transaction.get/1` after they return to your `success_url` / `failure_url`.

### SSE stream disconnects mid-payment

If a `{:poslink_payment_error, id, _reason}` message arrives before a terminal
status (`"SUCCESSFUL"`, `"FAILED"`, `"CANCELLED"`), the SSE connection dropped.
The payment may or may not have completed on the terminal. Check the current
state with `Teya.POSLink.Payment.get/2`, then
re-subscribe with `Teya.POSLink.Payment.subscribe/2` if still in progress.

### Auth token refresh failures

If the token endpoint is unreachable, the auth process schedules a retry after
10 seconds. While retrying, API calls return `{:error, reason}`. The cached
token (if any) remains usable until it expires. Once connectivity is restored,
the retry succeeds automatically — no restart required.

## Development

### Requirements

- Elixir 1.17+, Erlang/OTP 25+ (see `.tool-versions` for exact versions used locally)
- [Homebrew](https://brew.sh) (macOS/Linux) for dev tooling

### Setup

Install dependencies and git hooks:

```bash
./bin/setup
mix setup
```

`./bin/setup` installs [actionlint](https://github.com/rhysd/actionlint),
[check-jsonschema](https://github.com/python-jsonschema/check-jsonschema), and
[Lefthook](https://github.com/evilmartians/lefthook) via Homebrew, then
activates the pre-commit hooks.

This installs pre-commit hooks (`mix format`, `mix compile`) and pre-push hooks
(`mix credo`, `mix test`).

### Common commands

```sh
mix deps.get    # install dependencies
mix test        # run tests
mix format      # format code
mix docs        # generate documentation
```

Tests use `Req.Test` to stub HTTP — no network access or real credentials required.
