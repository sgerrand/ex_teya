defmodule Teya.Checkout do
  @moduledoc """
  Hosted Checkout sessions.

  Redirects customers to a Teya-hosted payment page. Your server creates a session
  and receives the `session_url` to redirect the customer to. Teya handles the
  payment UI and redirects back to your `success_url` or `failure_url` when done.

  Required OAuth scopes: `checkout/sessions/create`, `checkout/sessions/id/get`.
  """

  alias Teya.Client

  @doc """
  Creates a hosted checkout session.

  Returns `{:ok, %{"session_id" => id, "session_url" => url}}` on success.
  Redirect the customer to `session_url` to complete payment.

  ## Required params

  - `amount` — `%{"currency" => "GBP", "value" => 1000}` (value in minor units, max 9_223_372_036_854)
  - `type` — `"SALE"` or `"PRE_AUTHORISATION"`

  ## Optional params

  - `billing_address`, `cancel_url`, `customer`, `customer_success_email`,
    `failure_url`, `language` (IETF BCP 47, e.g. `"en-GB"`), `line_items`,
    `merchant_reference` (max 60 chars), `merchant_success_email`, `metadata`
    (max 10 keys), `post_success_payment` (`"SHOW_SUCCESS_PAGE"` or `"REDIRECT"`),
    `required_customer_fields`, `store_id` (UUID), `success_url`

  ## Options

  - `idempotency_key` — override the auto-generated idempotency key

  ## Examples

      params = %{
        "amount" => %{"currency" => "GBP", "value" => 1000},
        "type" => "SALE",
        "success_url" => "https://example.com/success",
        "failure_url" => "https://example.com/failure"
      }

      {:ok, %{"session_url" => url}} = Teya.Checkout.create_session(params)
  """
  @spec create_session(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create_session(params, opts \\ []) do
    Client.request(:post, "/v2/checkout/sessions", Keyword.put(opts, :body, params))
  end

  @doc """
  Retrieves a checkout session by its ID.

  The response includes `session_status` (`"ACTIVE"`, `"PROCESSING"`, `"COMPLETED"`,
  `"EXPIRED"`) and `payment_status` (`"NONE"`, `"SUCCESS"`, `"FAILED"`).

  ## Examples

      {:ok, session} = Teya.Checkout.get_session(session_id)
      session["payment_status"]  # "SUCCESS"
  """
  @spec get_session(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def get_session(session_id, opts \\ []) do
    Client.request(:get, "/v2/checkout/sessions/#{session_id}", opts)
  end
end
