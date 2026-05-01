defmodule Teya.Config do
  @moduledoc """
  Configuration for the Teya API client.

  Set in your application config:

      config :teya,
        client_id: "your_client_id",
        client_secret: "your_client_secret",
        token_url: "https://identity.teya.com/connect/token",
        base_url: "https://api.teya.com",
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
  """

  require Logger

  @type t :: %__MODULE__{
          client_id: String.t(),
          client_secret: String.t(),
          token_url: String.t(),
          base_url: String.t(),
          scopes: [String.t()]
        }

  defstruct [
    :client_id,
    :client_secret,
    token_url: "https://identity.teya.com/connect/token",
    base_url: "https://api.teya.com",
    scopes: []
  ]

  @doc false
  def from_env do
    %__MODULE__{
      client_id: Application.fetch_env!(:teya, :client_id),
      client_secret: Application.fetch_env!(:teya, :client_secret),
      token_url:
        Application.get_env(:teya, :token_url, "https://identity.teya.com/connect/token"),
      base_url: Application.get_env(:teya, :base_url, "https://api.teya.com"),
      scopes: Application.get_env(:teya, :scopes, [])
    }
    |> validate!()
  end

  defp validate!(%__MODULE__{} = config) do
    if blank?(config.client_id),
      do: raise(ArgumentError, "Teya: :client_id must be a non-empty string")

    if blank?(config.client_secret),
      do: raise(ArgumentError, "Teya: :client_secret must be a non-empty string")

    if config.scopes == [],
      do: Logger.warning("Teya: no :scopes configured — token requests will request no scopes")

    config
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
