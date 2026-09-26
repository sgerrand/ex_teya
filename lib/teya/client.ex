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

  Nothing else is read from `opts`. Settings for the underlying `Req`
  request, such as timeouts or extra headers, come from `:req_options`.
  """
  def request(method, path, opts \\ []) do
    with {:ok, token} <- Auth.token(), do: send_request(method, path, opts, token)
  end

  @doc """
  Makes a POST to an endpoint that honours the `Idempotency-Key` header.

  Teya's specs say that repeating such a request with the same key does not
  act a second time, so it is safe to retry. The retry may still fail, with a
  409 for a key already used say, after a first attempt that succeeded but
  whose response was lost; the README tells callers to check the outcome. When
  `:retry_idempotent_posts` is set, a network error, 408, 429 or 5xx is
  retried with Req's `retry: :transient`, sending the same key each time. A
  `:retry` in `:req_options` still wins. Takes the same options as
  `request/3`.

  Use it only for an endpoint whose spec documents the header. Anything
  else, such as a receipt that would be emailed twice, uses `request/3`.
  """
  def idempotent_post(path, opts) do
    retry = if Application.get_env(:teya, :retry_idempotent_posts, false), do: :transient

    with {:ok, token} <- Auth.token(),
         do: send_request(:post, path, opts, token, retry)
  end

  @doc """
  Makes a request with the given bearer token instead of the auth process's.

  For the rare endpoint that takes a different kind of token, such as ePOS
  registration, which takes a signed-in user's. It is a separate function,
  not an option of `request/3`, so a token cannot slip in through the
  options every resource function passes along. Takes the same options.
  """
  def request_with_token(token, method, path, opts) when is_binary(token) and token != "",
    do: send_request(method, path, opts, token)

  @doc false
  # Encodes one segment of a request path, so a value holding "/", "?", "#"
  # or a space cannot change which endpoint is called. An empty one, from nil
  # say, raises: it would leave "//" in the path and call some other route.
  # So do "." and "..", which encoding leaves as they are, and which a proxy
  # or server may read as "this level" and "the level above".
  # Anything but text or an integer, a map say, raises too.
  def segment(value) when is_integer(value), do: segment(Integer.to_string(value))

  def segment(value) when is_binary(value) and value not in ["", ".", ".."],
    do: URI.encode(value, &URI.char_unreserved?/1)

  def segment(value) do
    raise ArgumentError,
          "a request path segment must be text or an integer, and cannot be empty, " <>
            "\".\" or \"..\", got: #{inspect(value)}"
  end

  defp send_request(method, path, opts, token, retry \\ nil) do
    base_url = Application.get_env(:teya, :base_url, "https://api.teya.com")
    req_opts = Application.get_env(:teya, :req_options, [])

    req =
      [
        method: method,
        url: base_url <> path,
        # Req's own option, which gives way to a user-agent set in
        # :req_options, as an option or a header.
        user_agent: HTTP.user_agent(),
        receive_timeout: 30_000
      ]
      |> put_if_present(:json, Keyword.get(opts, :body))
      |> put_if_present(:params, Keyword.get(opts, :params))
      # Before the configured options, so a :retry among them wins.
      |> put_if_present(:retry, retry)
      |> Keyword.merge(req_opts)
      # Set after the configured options, so an :auth among them cannot send
      # the wrong credentials to Teya in place of this token.
      |> Keyword.put(:auth, {:bearer, token})
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
