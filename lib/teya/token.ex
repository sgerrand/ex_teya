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
  """
  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, Teya.Error.t()}
  def delete(token_id, store_id, opts \\ []) do
    case Client.request(
           :delete,
           "/v1/tokens/#{token_id}",
           Keyword.put(opts, :params, %{store_id: store_id})
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
