defmodule Teya.POSLink.Epos do
  @moduledoc """
  ePOS registration: exchanging a user's sign-in for machine credentials.

  An ePOS application registers once per store. Teya answers with a
  `client_id` and `client_secret` for machine-to-machine use, and the scopes
  they may request.

  Registering is a setup step, not something to do while the application
  runs. Store the credentials in your configuration as `:client_id`,
  `:client_secret` and `:scopes`, then restart the application: the library
  reads them once, when it starts, and only then begins fetching tokens.
  Setting them with `Application.put_env/3` while it runs changes nothing.

  Registration itself needs no `:client_id`: it runs before there is one.
  """

  alias Teya.Client

  @doc """
  Registers an ePOS application for a store and returns its credentials.

  This endpoint takes a token for a signed-in user with access to the store,
  not the machine-to-machine token the library fetches for everything else,
  so pass it as `:user_token`. Registering again with the same store and
  `epos_external_id` returns the same credentials.

  Returns `{:ok, response}` with `client_id`, `client_secret` and `scopes`,
  or `{:error, reason}`. The client secret is a credential: store it as you
  would a password, and keep it out of logs.

  Raises `ArgumentError` if `:user_token` is missing: that is a mistake in
  the calling code, not something the API said.

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
  def register(params, opts \\ []) do
    {user_token, opts} = Keyword.pop(opts, :user_token)

    if not (is_binary(user_token) and user_token != "") do
      raise ArgumentError,
            "Teya.POSLink.Epos.register/2 needs the signed-in user's token as :user_token"
    end

    Client.request_with_token(
      user_token,
      :post,
      "/poslink/v1/epos/register",
      Keyword.put(opts, :body, params)
    )
  end
end
