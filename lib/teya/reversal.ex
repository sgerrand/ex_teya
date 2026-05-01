defmodule Teya.Reversal do
  @moduledoc """
  Void a transaction before settlement.

  A reversal cancels a transaction that has not yet settled with the card
  network. For transactions that have already settled, use `Teya.Refund`
  instead.

  Required OAuth scope: `reversals/create`.
  """

  alias Teya.Client

  @doc """
  Creates a reversal.

  Either `transaction_id` or `idempotency_key` (the key from the original
  transaction request) must be included in `params` to identify the transaction.

  Returns `{:ok, response}` where `response["status"]` is `"SUCCESS"`,
  `"FAILURE"`, `"PENDING"`, or `"ACKNOWLEDGED"`. An `"ACKNOWLEDGED"` response
  (HTTP 202) means the reversal has been accepted but processing is not yet
  complete.

  ## Required params

  - `reversal_reason` — `"CARD_REVERSAL"`, `"CARD_REMOVED"`, or
    `"COMMUNICATION_REVERSAL"`

  One of:
  - `transaction_id` — ID of the transaction to reverse
  - `idempotency_key` — idempotency key used when creating the original transaction

  ## Options

  - `idempotency_key` — override the auto-generated idempotency key for *this*
    reversal request (distinct from the `idempotency_key` body field used to
    reference the original transaction)

  ## Examples

      {:ok, response} = Teya.Reversal.create(%{
        "reversal_reason" => "CARD_REVERSAL",
        "transaction_id"  => transaction_id
      })

      response["status"]           # "SUCCESS" | "FAILURE" | "PENDING" | "ACKNOWLEDGED"
      response["reversal_amount"]  # %{"amount" => 1000, "currency" => "GBP"}
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/v2/reversals", Keyword.put(opts, :body, params))
  end
end
