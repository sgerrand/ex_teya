defmodule Teya.POSLink.Epos do
  @moduledoc """
  ePOS registration: exchanging a user's sign-in for machine credentials.

  An ePOS application registers once per store. Teya answers with a
  `client_id` and `client_secret` for machine-to-machine use, and the scopes
  they may request. Configure the library with those, as `:client_id`,
  `:client_secret` and `:scopes`, and it fetches its own tokens from then on.
  """

  alias Teya.Client

  @doc """
  Registers an ePOS application for a store and returns its credentials.

  This endpoint takes a token for a signed-in user with access to the store,
  not the machine-to-machine token the library fetches for everything else,
  so pass it as `:user_token`. Registering again with the same store and
  `epos_external_id` returns the same credentials.

  Returns `{:ok, response}` with `client_id`, `client_secret` and `scopes`.
  The client secret is a credential: store it as you would a password, and
  keep it out of logs.

  ## Required params

  - `store_id` — UUID of the store
  - `epos_external_id` — your own identifier for this ePOS application

  ## Options

  - `:user_token` — the signed-in user's token (required)

  ## Examples

      {:ok, %{"client_id" => id, "client_secret" => secret, "scopes" => scopes}} =
        Teya.POSLink.Epos.register(
          %{"store_id" => store_id, "epos_external_id" => "till-1"},
          user_token: user_jwt
        )
  """
  @spec register(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def register(params, opts) do
    {user_token, opts} = Keyword.pop(opts, :user_token)

    unless is_binary(user_token) and user_token != "" do
      raise ArgumentError,
            "Teya.POSLink.Epos.register/2 needs the signed-in user's token as :user_token"
    end

    Client.request(
      :post,
      "/poslink/v1/epos/register",
      opts |> Keyword.put(:body, params) |> Keyword.put(:token, user_token)
    )
  end
end
