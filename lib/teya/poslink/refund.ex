defmodule Teya.POSLink.Refund do
  @moduledoc """
  POSLink refunds — return funds to a cardholder for a completed payment.

  This module targets the POSLink refund endpoint (`/poslink/v1/refunds`),
  which is distinct from the Online Payments refund endpoint (`/v3/refunds`
  via `Teya.Refund`). Use this module when refunding a payment that was
  originally processed through a POSLink terminal.

  Required OAuth scope: `poslink/refunds/create`.
  """

  alias Teya.Client

  @doc """
  Creates a POSLink refund.

  Returns `{:ok, response}` where `status` is `"SUCCESSFUL"`, `"FAILED"`, or
  `"PENDING"`. A `"PENDING"` status means the refund is still being processed.

  ## Required params

  - `store_id` — UUID of the store where the original payment was taken
  - `payment_request_id` — UUID of the payment request to refund

  ## Optional params

  - `requested_amount` — `%{"amount" => 1000, "currency" => "GBP"}` to
    partially refund; omit to refund the full payment amount
  - `merchant_reference` — caller-supplied reference (max 60 chars)

  ## Options

  - `:idempotency_key` — override the auto-generated idempotency key

  ## Examples

      {:ok, _} = Teya.POSLink.Refund.create(%{
        "store_id"           => store_id,
        "payment_request_id" => payment_request_id
      })
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/poslink/v1/refunds", Keyword.put(opts, :body, params))
  end
end
