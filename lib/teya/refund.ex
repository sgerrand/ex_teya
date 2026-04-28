defmodule Teya.Refund do
  @moduledoc """
  Refund completed transactions.

  Required OAuth scope: `refunds/create`.
  """

  alias Teya.Client

  @doc """
  Creates a refund.

  Returns `{:ok, response}` where status is `"SUCCESS"`, `"FAILURE"`, or `"PENDING"`.
  A `"PENDING"` response (HTTP 202) means the refund is still being processed.

  Note: HTTP 460 indicates a challenge is required before the refund can proceed.

  ## Options

  - `idempotency_key` — override the auto-generated idempotency key
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/v3/refunds", Keyword.put(opts, :body, params))
  end
end
