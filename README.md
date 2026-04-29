# Teya

Elixir client for the [Teya API](https://docs.teya.com/apis/overview).

## Installation

Add `teya` to your dependencies in `mix.exs`:

<!-- x-release-please-start-version -->
```elixir
def deps do
  [
    {:teya, "~> 0.1.0"}
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
    "checkout/sessions/create",
    "checkout/sessions/id/get",
    "payment-links/create",
    "payment-links/id/get",
    "payment-links/id/update",
    "transactions/online/create",
    "transactions/online/id/get",
    "captures/create",
    "refunds/create",
    "transactions/id/receipts/create",
    "token/delete"
  ]
```

OAuth tokens are fetched automatically and refreshed before expiry. Only request the scopes your application needs.

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
