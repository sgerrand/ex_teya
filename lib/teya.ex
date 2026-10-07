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

  For one set of credentials, such as the client from the Teya Developer
  Portal for Online Payments and Payments Gateway:

      config :teya,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
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

  POSLink uses a different client, the one ePOS registration returns, once
  per store, with the scopes it returns. To use both, or several stores, name
  each set under `:credentials`, reading the secrets when the application
  starts:

      # config/runtime.exs
      config :teya,
        credentials: [
          online: [
            client_id: System.fetch_env!("TEYA_CLIENT_ID"),
            client_secret: System.fetch_env!("TEYA_CLIENT_SECRET"),
            scopes: ["checkout/sessions/create", "checkout/sessions/id/get"]
          ],
          poslink: [
            client_id: System.fetch_env!("TEYA_EPOS_CLIENT_ID"),
            client_secret: System.fetch_env!("TEYA_EPOS_CLIENT_SECRET"),
            # the "scopes" list from registration, separated by spaces or
            # commas, such as "payment_requests payment_requests/id"
            scopes: String.split(System.fetch_env!("TEYA_EPOS_SCOPES"), ~r/[\\s,]+/, trim: true)
          ]
        ]

  Each set gets its own token and asks only for its own scopes. A call uses
  the set named with its `:credentials` option, else `:poslink` for a POSLink
  call or `:online` for any other when that set is configured, else the
  top-level credentials. Ask each client only for the scopes it was given:
  others can make its token request fail with `invalid_scope`.

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

  All functions that call Teya return `{:ok, response_body}` or
  `{:error, %Teya.Error{}}`. Pattern-match on `%Teya.Error{code: code}` for
  Teya-specific error codes, and see `Teya.Error` for a request with no
  usable answer. `Teya.Webhook` checks an incoming webhook instead, and says
  what it returns.

      case Teya.Checkout.create_session(params) do
        {:ok, %{"session_url" => url}} -> redirect(conn, external: url)
        {:error, %Teya.Error{code: "TOO_MANY_REQUESTS"}} -> {:error, :rate_limited}
        {:error, %Teya.Error{} = err} -> {:error, err}
      end

  ## Idempotency

  A request whose Teya spec documents the `Idempotency-Key` header, such as
  `Teya.Checkout.create_session/2`, carries one: a random key, or your own,
  passed as `idempotency_key: "your-key"` in the options:

      Teya.Checkout.create_session(params, idempotency_key: order_id)

  Every other request carries none, since Teya documents none for it. Every
  other write also raises `ArgumentError` if given an `:idempotency_key`, so
  you learn it is not sent; reads ignore it. The README lists which is
  which.
  """
end
