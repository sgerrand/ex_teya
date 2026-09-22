defmodule Teya.POSLink.Refund do
  @moduledoc """
  POSLink refunds — return funds to a cardholder for a completed payment.

  This module targets the POSLink refund endpoint (`/poslink/v2/refunds`),
  which is distinct from the Online Payments refund endpoint (`/v3/refunds`
  via `Teya.Refund`). Use this module when refunding a payment that was
  originally processed through a POSLink terminal.

  Required OAuth scope: `poslink/refunds/create`.
  """

  alias Teya.Client

  @doc """
  Creates a POSLink refund.

  Returns `{:ok, response}` where `status` is `"SUCCESS"`, `"FAILURE"`, or
  `"PENDING"`. A `"PENDING"` status means the refund is still being processed.

  ## Required params

  - `transaction_id` — the `gateway_payment_id` of the original payment, sent
    on its status stream when the payment completes (see
    `Teya.POSLink.Payment.subscribe/2`). Do not send the payment's
    `transaction_id`: it is a different identifier and the refund fails with
    `404 TRANSACTION_NOT_FOUND`.
  - `amount` — amount to refund, in minor units

  ## Optional params

  - `currency` — ISO 4217 currency code
  - `terminal_id` — terminal to process the refund on
  - `merchant_reference` — caller-supplied reference (max 60 chars)
  - `basket_transaction_id` — identifier of the basket in the ePOS

  ## Options

  - `:idempotency_key` — override the auto-generated idempotency key

  ## Examples

      {:ok, _} = Teya.POSLink.Refund.create(%{
        "transaction_id" => payment["gateway_payment_id"],
        "amount"         => 1500
      })
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/poslink/v2/refunds", Keyword.put(opts, :body, params))
  end
end
