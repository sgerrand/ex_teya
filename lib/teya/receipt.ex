defmodule Teya.Receipt do
  @moduledoc """
  Digital receipts for completed transactions.

  Required OAuth scope: `transactions/id/receipts/create`.
  """

  alias Teya.Client

  @doc """
  Creates a digital receipt for a transaction.

  `transaction_id` is the UUID of the completed transaction. The API returns HTTP 202
  (accepted for processing) on success — receipt delivery is asynchronous.

  ## Options

  - `idempotency_key` — override the auto-generated idempotency key
  """
  @spec create(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(transaction_id, params \\ %{}, opts \\ []) do
    Client.request(
      :post,
      "/v1/transactions/#{transaction_id}/receipts",
      Keyword.put(opts, :body, params)
    )
  end
end
