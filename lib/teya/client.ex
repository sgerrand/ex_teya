defmodule Teya.Client do
  @moduledoc false

  alias Teya.{Auth, Error}

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
          headers: idempotency_headers(method, opts),
          receive_timeout: 30_000
        ]
        |> put_if_present(:json, Keyword.get(opts, :body))
        |> put_if_present(:params, Keyword.get(opts, :params))
        |> Keyword.merge(req_opts)

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
