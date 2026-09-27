defmodule Teya.Config do
  @moduledoc """
  Configuration for the Teya API client.

  Set in your application config:

      config :teya,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
        scopes: [
          "checkout/sessions/create",
          "checkout/sessions/id/get",
          "payment-links/create",
          "payment-links/id/get",
          "payment-links/id/update",
          "transactions/online/create",
          "transactions/online/id/get",
          "captures/create",
          "refunds/create",
          "transactions/id/receipts/create",
          "token/delete"
        ]

  More sets of credentials can be named under `:credentials`, each with its
  own `:client_id`, `:client_secret` and `:scopes`; see the README.

  The API and token URLs come from `:environment`, `:production` (the
  default) or `:staging`. Set `:base_url` or `:token_url` to use another.
  Set these before the application starts. The auth process reads the
  credentials and the token URL once, when it starts, and keeps the token it
  fetched, while API calls read `:environment` and `:base_url` on every
  request. Changing them while the application runs sends API calls to the
  new host with a token from the old one. To switch, restart the application.
  """

  alias Teya.HTTP

  require Logger

  @type t :: %__MODULE__{
          name: atom() | nil,
          client_id: String.t(),
          client_secret: String.t(),
          token_url: String.t(),
          scopes: [String.t()]
        }

  # name is nil for the top-level credentials, or a set's name.
  defstruct [:name, :client_id, :client_secret, :token_url, scopes: []]

  @doc false
  # The top-level credentials.
  def from_env do
    %__MODULE__{
      client_id: Application.fetch_env!(:teya, :client_id),
      client_secret: Application.fetch_env!(:teya, :client_secret),
      token_url: HTTP.token_url(),
      scopes: Application.get_env(:teya, :scopes, [])
    }
    |> validate!()
  end

  @doc false
  # A named set from `:credentials`.
  def from_env(name) do
    set = Keyword.fetch!(sets(), name)

    %__MODULE__{
      name: name,
      client_id: Keyword.get(set, :client_id),
      client_secret: Keyword.get(set, :client_secret),
      token_url: HTTP.token_url(),
      scopes: Keyword.get(set, :scopes, [])
    }
    |> validate!()
  end

  @doc false
  # The named sets, as configured.
  def sets, do: Application.get_env(:teya, :credentials, [])

  defp validate!(%__MODULE__{} = config) do
    where = where(config.name)

    if blank?(config.client_id),
      do: raise(ArgumentError, "Teya: :client_id#{where} must be a non-empty string")

    if blank?(config.client_secret),
      do: raise(ArgumentError, "Teya: :client_secret#{where} must be a non-empty string")

    if config.scopes == [],
      do:
        Logger.warning(
          "Teya: no :scopes configured#{where} — token requests will request no scopes"
        )

    config
  end

  defp where(nil), do: ""
  defp where(name), do: " in the #{inspect(name)} credentials"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
