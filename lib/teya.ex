defmodule Teya do
  @moduledoc """
  Elixir client for the Teya APIs:

  - **[Online Payments](https://docs.teya.com/apis/online-payments/apis)** —
    hosted checkout, embedded card forms, pay-by-link, and token management
  - **[Payments Gateway](https://docs.teya.com/apis/payments/openapi.yaml)** —
    direct terminal integration for card-present transactions and reversals
  - **[Dynamic Currency Conversion](https://docs.teya.com/apis/dynamic-currency-conversion/openapi.yaml)** —
    unauthenticated BIN eligibility check and real-time exchange rate quotes
  - **[POSLink](https://docs.teya.com/apis/poslink/openapi.yaml)** —
    ePOS middleware for Teya-managed payment terminals

  ## Configuration

  The library runs one set of credentials, so configure one of these two,
  not both:

  - **Online Payments and Payments Gateway**: the client from the Teya
    Developer Portal.
  - **POSLink**: the client that ePOS registration returns.

  For Online Payments and Payments Gateway:

      config :teya,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
        scopes: [
          # Online Payments
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

  For POSLink, instead: store the client id, secret and scopes that
  registration returns where your application keeps its secrets, such as
  environment variables, and read them when it starts:

      # config/runtime.exs
      config :teya,
        client_id: System.fetch_env!("TEYA_EPOS_CLIENT_ID"),
        client_secret: System.fetch_env!("TEYA_EPOS_CLIENT_SECRET"),
        # the "scopes" list from registration, separated by spaces or commas,
        # such as "payment_requests payment_requests/id stores/id/terminals refunds"
        scopes: String.split(System.fetch_env!("TEYA_EPOS_SCOPES"), ~r/[\\s,]+/, trim: true)

  Ask a POSLink client only for the scopes registration gave it. Asking for
  others, such as the Online Payments ones above, can make the token request
  fail with `invalid_scope`.

  OAuth tokens are fetched automatically and refreshed before expiry.
  Only request the scopes your application needs. The
  [scope reference](readme.html#scope-reference) shows which function needs
  which.

  The library talks to Teya's production API unless you set
  `environment: :staging`. Set `:base_url` or `:token_url` to use other URLs.

  ## API modules

  ### Online Payments

  | Module | Purpose |
  |---|---|
  | `Teya.Checkout` | Hosted checkout — redirect customers to Teya's payment page |
  | `Teya.Transaction` | Direct card processing for embedded payment UIs |
  | `Teya.PayByLink` | Generate and manage shareable payment links |
  | `Teya.Capture` | Capture pre-authorised funds |
  | `Teya.Refund` | Refund completed transactions |
  | `Teya.Receipt` | Send digital receipts |
  | `Teya.Token` | Manage saved payment method tokens |

  ### Payments Gateway

  | Module | Purpose |
  |---|---|
  | `Teya.CardPresent` | Card-present transactions with raw EMV/track data |
  | `Teya.Reversal` | Void unsettled transactions |

  ### Dynamic Currency Conversion

  | Module | Purpose |
  |---|---|
  | `Teya.DCC` | BIN eligibility check and an exchange rate offer, with a quote to pay against |

  ### POSLink

  | Module | Purpose |
  |---|---|
  | `Teya.POSLink.Payment` | Create payment requests and stream status events |
  | `Teya.POSLink.Refund` | Refund a POSLink payment |
  | `Teya.POSLink.Receipt` | Print receipts and stream printer status |
  | `Teya.POSLink.Store` | List stores and terminals |

  ## Error handling

  All functions return `{:ok, response_body}` or `{:error, %Teya.Error{}}`.
  Pattern-match on `%Teya.Error{code: code}` for Teya-specific error codes.

      case Teya.Checkout.create_session(params) do
        {:ok, %{"session_url" => url}} -> redirect(conn, external: url)
        {:error, %Teya.Error{code: "TOO_MANY_REQUESTS"}} -> {:error, :rate_limited}
        {:error, %Teya.Error{} = err} -> {:error, err}
      end

  ## Idempotency

  POST and PATCH requests automatically include a random `Idempotency-Key` header,
  except DCC offers, whose endpoint documents none. Pass
  `idempotency_key: "your-key"` in the options to supply your own:

      Teya.Checkout.create_session(params, idempotency_key: order_id)
  """
end
