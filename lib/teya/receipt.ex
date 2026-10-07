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

  Raises `ArgumentError` if given an `:idempotency_key`: Teya documents no
  `Idempotency-Key` header for this endpoint, so none is sent.

  ## Examples

      {:ok, _} = Teya.Receipt.create(transaction_id, %{"email" => "customer@example.com"})
  """
  @spec create(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(transaction_id, params \\ %{}, opts \\ []) do
    Client.request(
      :post,
      {"/v1/transactions/:id/receipts", id: transaction_id},
      Keyword.put(opts, :body, params)
    )
  end
end
