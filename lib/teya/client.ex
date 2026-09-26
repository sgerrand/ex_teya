defmodule Teya.Client do
  @moduledoc false

  alias Teya.{Auth, Error, HTTP}

  @max_retry_after_ms 10_000

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
    with {:ok, token} <- Auth.token(),
         do: send_request(method, path, opts, token, refresh_token: true)
  end

  @doc """
  Makes a POST to an endpoint that honours the `Idempotency-Key` header.

  Teya's specs say that repeating such a request with the same key does not
  act a second time, so it is safe to retry. The retry may still fail, with a
  409 for a key already used say, after a first attempt that succeeded but
  whose response was lost; the README tells callers to check the outcome.

  When `:retry_idempotent_posts` is set, the request is retried on what
  Req's `retry: :transient` retries, sending the same key each time, except
  a 429 or 503 whose `Retry-After` asks for a longer wait than
  #{div(@max_retry_after_ms, 1000)} seconds, or cannot be read. The caller
  would sit blocked for that wait, so the error comes back at once. A
  `:retry` in `:req_options` still wins. Takes the same options as
  `request/3`.

  Use it only for an endpoint whose spec documents the header. Anything
  else, such as a receipt that would be emailed twice, uses `request/3`.
  """
  def idempotent_post(path, opts) do
    retry =
      if Application.get_env(:teya, :retry_idempotent_posts, false), do: &transient?/2

    with {:ok, token} <- Auth.token(),
         do: send_request(:post, path, opts, token, refresh_token: true, retry: retry)
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

  # settings, for this library's callers only:
  # - :refresh_token — the token came from the auth process, so a retry asks
  #   it again
  # - :retry — Req's :retry option, unless :req_options sets one
  defp send_request(method, path, opts, token, settings \\ []) do
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
      |> put_if_present(:retry, settings[:retry])
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
      |> refresh_token_on_retry(settings[:refresh_token])

    case Req.request(req) do
      {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, resp.body}
      {:ok, resp} -> {:error, Error.from_response(resp)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Retries can run for minutes, past the life of the token the first
  # attempt was sent with, so each retry asks the auth process for its
  # current one. Req runs every request step again on a retry; the first run
  # only marks the request as sent. If the auth process has no token to
  # give, the retry goes with the old one and its answer says so.
  defp refresh_token_on_retry(req, true),
    do: Req.Request.append_request_steps(req, teya_refresh_token: &refresh_token/1)

  defp refresh_token_on_retry(req, _no), do: req

  defp refresh_token(req) do
    with true <- Req.Request.get_private(req, :teya_sent, false),
         {:ok, token} <- Auth.token() do
      Req.Request.put_header(req, "authorization", "Bearer " <> token)
    else
      false -> Req.Request.put_private(req, :teya_sent, true)
      {:error, _reason} -> req
    end
  end

  # What Req's retry: :transient retries, but not a 429 or 503 that asks for
  # a wait longer than @max_retry_after_ms, nor one whose Retry-After cannot
  # be read, which Req would raise on.
  defp transient?(_req, %Req.Response{status: status} = resp) when status in [429, 503] do
    case retry_after_ms(resp) do
      :unreadable -> false
      nil -> true
      ms -> ms <= @max_retry_after_ms
    end
  end

  defp transient?(_req, %Req.Response{status: status}), do: status in [408, 500, 502, 504]

  defp transient?(_req, %Req.TransportError{reason: reason}),
    do: reason in [:timeout, :econnrefused, :closed]

  defp transient?(_req, %Req.HTTPError{protocol: :http2, reason: reason}),
    do: reason in [:unprocessed, :pool_not_available]

  defp transient?(_req, _other), do: false

  defp retry_after_ms(resp) do
    Req.Response.get_retry_after(resp)
  rescue
    _error -> :unreadable
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
