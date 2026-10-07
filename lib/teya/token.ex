defmodule Teya.Token do
  @moduledoc """
  Saved payment method tokens.

  Tokens are created by passing `store_payment_method: true` in a `Teya.Transaction`
  request. The returned `token_id` can be used in subsequent transactions as a
  `"TOKEN"` payment method.

  Required OAuth scope: `token/delete`.
  """

  alias Teya.Client

  @doc """
  Deletes a saved payment method token.

  `store_id` is required — tokens are scoped to a store and only the owning store
  may delete them. Returns `:ok` on success (HTTP 204).

  Raises `ArgumentError` if given an `:idempotency_key`: Teya documents no
  `Idempotency-Key` header for this endpoint, so none is sent.

  ## Examples

      :ok = Teya.Token.delete(token_id, store_id)
  """
  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, Teya.Error.t()}
  def delete(token_id, store_id, opts \\ []) do
    path = {"/v1/tokens/:id", id: token_id}

    with {:ok, _body} <-
           Client.request(:delete, path, Keyword.put(opts, :params, %{store_id: store_id})),
         do: :ok
  end
end
