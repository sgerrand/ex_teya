defmodule Teya.Transaction do
  @moduledoc """
  Online transactions for embedded payment flows.

  Use this when you control the payment UI (embedded card form, Apple Pay, or
  stored tokens). For a Teya-hosted UI, see `Teya.Checkout`.

  The API supports 3DS flows: a `"REDIRECT_TRANSACTION_RESPONSE"` type in the
  response means the customer must complete a 3DS challenge at the returned URL
  before the transaction is finalised.

  Required OAuth scopes: `transactions/online/create`, `transactions/online/id/get`.
  """

  alias Teya.Client

  @doc """
  Processes an online transaction.

  Returns `{:ok, response}` where `response["type"]` is one of:
  - `"ONLINE_TRANSACTION"` — transaction completed; check `response["online_transaction"]["status"]`
  - `"REDIRECT_TRANSACTION_RESPONSE"` — 3DS challenge required; redirect the customer

  Transaction statuses: `"SUCCESS"`, `"FAILURE"`, `"PENDING"`.

  ## Required params

  - `amount` — `%{"currency" => "GBP", "value" => 1000}`
  - `initiator` — `"CUSTOMER"` or `"MERCHANT"`
  - `payment_method` — `%{"type" => "CARD", "card" => %{...}}` (see below)
  - `store_id` — UUID
  - `type` — `"SALE"`, `"PRE_AUTHORISATION"`, or `"ACCOUNT_VERIFICATION"`

  ## Payment method types

  Card: `%{"type" => "CARD", "card" => %{"number" => "...", "expiry_month" => "12",
  "expiry_year" => "2028", "cvc" => "123"}}`

  Token: `%{"type" => "TOKEN", "token" => %{"token_id" => uuid,
  "recurring_payment_type" => "CARD_ON_FILE"}}`

  Apple Pay: `%{"type" => "APPLE_PAY", "apple_pay_authentication_data" => %{...}}`

  ## Optional params

  - `billing_address`, `browser_data` (required for 3DS; must include `ip_address`,
    `screen_height`, `screen_width`), `cardholder`, `customer_contact`, `line_items`,
    `merchant_reference_id` (max 60 chars), `redirect_url`, `shipping_address`,
    `store_payment_method`

  ## Options

  - `idempotency_key` — override the auto-generated idempotency key
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/v3/transactions/online", Keyword.put(opts, :body, params))
  end

  @doc """
  Retrieves an online transaction by its authentication ID.

  `authentication_id` is returned in the `create/2` response.
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def get(authentication_id, opts \\ []) do
    Client.request(:get, "/v2/transactions/online/#{authentication_id}", opts)
  end
end
