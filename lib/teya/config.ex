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
  `:default` names the top-level credentials, so no set can use it.

  The API and token URLs come from `:environment`, `:production` (the
  default) or `:staging`. Set `:base_url` or `:token_url` to use another.
  Each set of credentials reads these once, when its auth process starts:
  its token URL and its API's base URL are resolved together, and every
  request made with its token goes to that host. A change while the
  application runs has no effect until the next start, so a token is never
  sent to another environment's host. To switch, restart the application.
  """

  alias Teya.HTTP

  require Logger

  @type t :: %__MODULE__{
          name: atom() | nil,
          client_id: String.t(),
          client_secret: String.t(),
          token_url: String.t(),
          base_url: String.t(),
          scopes: [String.t()]
        }

  # name is nil for the top-level credentials, or a set's name. token_url
  # and base_url are resolved together, so a token and the host it is sent
  # to always come from the same environment.
  defstruct [:name, :client_id, :client_secret, :token_url, :base_url, scopes: []]

  @doc false
  # The top-level credentials.
  def from_env do
    %__MODULE__{
      client_id: Application.fetch_env!(:teya, :client_id),
      client_secret: Application.fetch_env!(:teya, :client_secret),
      token_url: HTTP.token_url(),
      base_url: HTTP.base_url(),
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
      base_url: HTTP.base_url(),
      scopes: Keyword.get(set, :scopes, [])
    }
    |> validate!()
  end

  @doc false
  # The named sets, as configured, checked so that a mistake stops the
  # application at boot with a clear message. The messages never show a
  # set's values, which hold its secret.
  def sets do
    case Application.get_env(:teya, :credentials, []) do
      sets when is_list(sets) -> check_sets!(sets)
      _other -> raise ArgumentError, "Teya: :credentials must be a keyword list of named sets"
    end
  end

  # nil and :default name the top-level credentials.
  @reserved [nil, :default]

  defp check_sets!(sets) do
    Enum.each(sets, fn
      {name, set} when is_atom(name) and name not in @reserved and is_list(set) ->
        if not Keyword.keyword?(set),
          do:
            raise(ArgumentError, "Teya: the #{inspect(name)} credentials must be a keyword list")

      {name, _set} when name in @reserved ->
        raise ArgumentError,
              "Teya: #{inspect(name)} names the top-level credentials; give the set another name"

      _entry ->
        raise ArgumentError,
              "Teya: :credentials must be a keyword list of sets named with atoms"
    end)

    names = Keyword.keys(sets)

    if length(Enum.uniq(names)) != length(names),
      do: raise(ArgumentError, "Teya: a name appears twice under :credentials")

    sets
  end

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
