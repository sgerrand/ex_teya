defmodule Teya.Client do
  @moduledoc false

  alias Teya.{Auth, Error}

  @version Mix.Project.config()[:version]
  @user_agent "teya-elixir/#{@version}"

  @doc false
  def user_agent, do: @user_agent

  @doc false
  # Req options are merged last, so headers set there replace the list built
  # here outright. Fold them together first: a caller's header wins by name,
  # and the rest of ours survive.
  def merge_headers(req_opts, defaults) do
    configured = req_opts |> Keyword.get(:headers, []) |> normalise_headers()
    names = MapSet.new(configured, fn {name, _value} -> name end)

    Enum.reject(defaults, fn {name, _value} -> MapSet.member?(names, name) end) ++ configured
  end

  defp normalise_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {name, value} -> {normalise_name(name), value} end)
  end

  defp normalise_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {name, value} ->
      name = normalise_name(name)
      value |> List.wrap() |> Enum.map(&{name, &1})
    end)
  end

  # Match how Req names headers, or a caller's header would not line up with
  # ours and both would be sent: an atom name has its underscores turned into
  # dashes, so :user_agent is the "user-agent" header.
  defp normalise_name(name) when is_atom(name) do
    name |> Atom.to_string() |> String.replace("_", "-")
  end

  defp normalise_name(name), do: String.downcase(name)

  @doc """
  Makes an authenticated HTTP request to the Teya API.

  Fetches a bearer token from `Teya.Auth`, builds the request, and returns
  `{:ok, body}` for 2xx responses or `{:error, reason}` otherwise.

  ## Options

  - `:body` — request body, serialised as JSON
  - `:params` — query parameters map or keyword list
  - `:idempotency_key` — custom idempotency key for POST/PATCH (auto-generated if omitted)

  All other options are merged into the underlying `Req` request.
  """
  def request(method, path, opts \\ []) do
    with {:ok, token} <- Auth.token() do
      base_url = Application.get_env(:teya, :base_url, "https://api.teya.com")
      req_opts = Application.get_env(:teya, :req_options, [])

      req =
        [
          method: method,
          url: base_url <> path,
          auth: {:bearer, token},
          receive_timeout: 30_000
        ]
        |> put_if_present(:json, Keyword.get(opts, :body))
        |> put_if_present(:params, Keyword.get(opts, :params))
        |> Keyword.merge(req_opts)
        |> Keyword.put(
          :headers,
          merge_headers(req_opts, [
            {"user-agent", @user_agent} | idempotency_headers(method, opts)
          ])
        )

      case Req.request(req) do
        {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, resp.body}
        {:ok, resp} -> {:error, Error.from_response(resp)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp idempotency_headers(method, opts) when method in [:post, :patch] do
    key = Keyword.get_lazy(opts, :idempotency_key, &generate_key/0)
    [{"idempotency-key", key}]
  end

  defp idempotency_headers(_method, _opts), do: []

  defp generate_key do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
