defmodule Teya.Client do
  @moduledoc false

  alias Teya.{Auth, Error, HTTP}

  @doc """
  Makes an authenticated HTTP request to the Teya API.

  Fetches a bearer token from `Teya.Auth`, builds the request, and returns
  `{:ok, body}` for 2xx responses or `{:error, reason}` otherwise.

  ## Options

  - `:body` — request body, serialised as JSON
  - `:params` — query parameters map or keyword list
  - `:idempotency_key` — custom idempotency key for POST/PATCH (auto-generated if omitted)
  - `:token` — a bearer token to send in place of the auth process's own, for
    the rare endpoint that takes a different kind of token

  Nothing else is read from `opts`. Settings for the underlying `Req`
  request, such as timeouts or extra headers, come from `:req_options`.
  """
  def request(method, path, opts \\ []) do
    with {:ok, token} <- bearer_token(opts) do
      base_url = Application.get_env(:teya, :base_url, "https://api.teya.com")
      req_opts = Application.get_env(:teya, :req_options, [])

      req =
        [
          method: method,
          url: base_url <> path,
          auth: {:bearer, token},
          # Req's own option, which gives way to a user-agent set in
          # :req_options, as an option or a header.
          user_agent: HTTP.user_agent(),
          receive_timeout: 30_000
        ]
        |> put_if_present(:json, Keyword.get(opts, :body))
        |> put_if_present(:params, Keyword.get(opts, :params))
        |> Keyword.merge(req_opts)
        |> Req.new()
        # Any idempotency-key set in config is dropped, whatever the method:
        # one key there would mark every POST as a retry of the first, and it
        # means nothing on other methods. POST and PATCH get their own.
        |> Req.Request.delete_header("idempotency-key")
        |> Req.merge(headers: idempotency_headers(method, opts))

      case Req.request(req) do
        {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, resp.body}
        {:ok, resp} -> {:error, Error.from_response(resp)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp bearer_token(opts) do
    case Keyword.fetch(opts, :token) do
      {:ok, token} -> {:ok, token}
      :error -> Auth.token()
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
