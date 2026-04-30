defmodule Teya.PayByLink do
  @moduledoc """
  Pay By Link — generate and manage shareable payment links.

  Payment links can be sent to customers via email, SMS, or any channel. Each link
  is single-use by default and expires at a configurable time.

  Required OAuth scopes: `payment-links/create`, `payment-links/id/get`,
  `payment-links/id/update`.
  """

  alias Teya.Client

  @doc """
  Creates a payment link.

  Returns `{:ok, %{"payment_link_id" => id, "payment_link" => url}}` on success.

  ## Required params

  - `amount` — `%{"currency" => "GBP", "value" => 1000}`

  ## Optional params

  - `billing_address`, `cancel_url` (HTTPS), `customer`, `customer_success_email`,
    `delivery_info`, `expires_at` (ISO 8601 datetime), `language` (IETF BCP 47),
    `line_items`, `merchant_reference` (max 60 chars), `merchant_success_email`,
    `metadata` (max 10 keys), `post_success_payment`, `required_customer_fields`,
    `store_id` (UUID), `success_url` (HTTPS),
    `supported_card_brands` (`"AMEX"`, `"MASTERCARD"`, `"VISA"`, ...),
    `supported_payment_methods` (`"CARD"`, `"TOKEN"`, `"APPLE_PAY"`),
    `transaction_type` (`"SALE"`, `"PRE_AUTHORISATION"`, `"ACCOUNT_VERIFICATION"`),
    `type` (`"SINGLE_USE"`)

  ## Options

  - `idempotency_key` — override the auto-generated idempotency key

  ## Examples

      {:ok, %{"payment_link" => url}} =
        Teya.PayByLink.create(%{
          "amount" => %{"currency" => "GBP", "value" => 5000},
          "expires_at" => "2024-12-31T23:59:59Z"
        })
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/v2/payment-links", Keyword.put(opts, :body, params))
  end

  @doc """
  Retrieves a payment link by its ID.

  The response includes `status`: `"VALID"`, `"COMPLETED"`, `"MANUALLY_EXPIRED"`,
  `"DISABLED"`, or `"EXPIRED"`.

  ## Examples

      {:ok, link} = Teya.PayByLink.get(payment_link_id)
      link["status"]  # "VALID" | "COMPLETED" | "EXPIRED"
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def get(payment_link_id, opts \\ []) do
    Client.request(:get, "/v1/payment-links/#{payment_link_id}", opts)
  end

  @doc """
  Updates a payment link.

  Currently supports updating `expires_at` (ISO 8601 datetime string) to extend
  or shorten the link's validity.

  ## Options

  - `idempotency_key` — override the auto-generated idempotency key

  ## Examples

      {:ok, _} = Teya.PayByLink.update(payment_link_id, %{"expires_at" => "2025-06-30T23:59:59Z"})
  """
  @spec update(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def update(payment_link_id, params, opts \\ []) do
    Client.request(
      :patch,
      "/v2/payment-links/#{payment_link_id}",
      Keyword.put(opts, :body, params)
    )
  end
end
