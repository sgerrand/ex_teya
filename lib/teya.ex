defmodule Teya do
  @moduledoc """
  Elixir client for the [Teya Online Payments API](https://docs.teya.com/apis/online-payments/apis).

  ## Configuration

  Add to your application config:

      config :teya,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
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

  OAuth tokens are fetched automatically via `Teya.Auth` and refreshed before
  expiry. Only request the scopes your application needs.

  ## API modules

  | Module | Purpose |
  |---|---|
  | `Teya.Checkout` | Hosted checkout — redirect customers to Teya's payment page |
  | `Teya.Transaction` | Direct card processing for embedded payment UIs |
  | `Teya.PayByLink` | Generate and manage shareable payment links |
  | `Teya.Capture` | Capture pre-authorised funds |
  | `Teya.Refund` | Refund completed transactions |
  | `Teya.Receipt` | Send digital receipts |
  | `Teya.Token` | Manage saved payment method tokens |

  ## Error handling

  All functions return `{:ok, response_body}` or `{:error, %Teya.Error{}}`.
  Pattern-match on `%Teya.Error{code: code}` for Teya-specific error codes.

      case Teya.Checkout.create_session(params) do
        {:ok, %{"session_url" => url}} -> redirect(conn, external: url)
        {:error, %Teya.Error{code: "TOO_MANY_REQUESTS"}} -> {:error, :rate_limited}
        {:error, %Teya.Error{} = err} -> {:error, err}
      end

  ## Idempotency

  POST and PATCH requests automatically include a random `Idempotency-Key` header.
  Pass `idempotency_key: "your-key"` in the options to supply your own:

      Teya.Checkout.create_session(params, idempotency_key: order_id)
  """
end
