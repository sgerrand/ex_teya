defmodule Teya.Capture do
  @moduledoc """
  Capture pre-authorised funds.

  After a `PRE_AUTHORISATION` transaction succeeds, call `create/2` to settle
  the funds. Uncaptured pre-authorisations are released automatically by the
  issuer after a network-defined period (typically 7 days).

  Required OAuth scope: `captures/create`.
  """

  alias Teya.Client

  @doc """
  Captures a pre-authorised transaction.

  `transaction_id` is the `transaction_id` from the `PRE_AUTHORISATION` response.

  Returns `{:ok, response}` where status is `"SUCCESS"`, `"FAILURE"`, or `"PENDING"`.
  A `"PENDING"` response (HTTP 202) means the capture is still being processed;
  poll `Teya.Transaction.get/1` until the status is final.

  ## Options

  - `idempotency_key` — override the auto-generated idempotency key
  """
  @spec create(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(transaction_id, params \\ %{}, opts \\ []) do
    Client.request(
      :post,
      "/v1/transactions/#{transaction_id}/capture",
      Keyword.put(opts, :body, params)
    )
  end
end
