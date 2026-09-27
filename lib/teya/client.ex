defmodule Teya.Client do
  @moduledoc false

  alias Teya.{Auth, Error, HTTP}

  @max_retry_after_ms 10_000

  @doc """
  Makes an authenticated HTTP request to the Teya API.

  Fetches a bearer token from `Teya.Auth`, builds the request, and returns
  `{:ok, body}` for 2xx responses or `{:error, %Teya.Error{}}` otherwise.

  ## Options

  - `:body` — request body, serialised as JSON
  - `:params` — query parameters map or keyword list
  - `:idempotency_key` — custom idempotency key for POST/PATCH (auto-generated if omitted)
  - `:credentials` — the named set of credentials to use; see `Teya.Auth.set_for/2`

  Nothing else is read from `opts`. Settings for the underlying `Req`
  request, such as timeouts or extra headers, come from `:req_options`.
  """
  def request(method, path, opts \\ []) do
    authed_request(method, path, opts, [])
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

    authed_request(:post, path, opts, retry: retry)
  end

  @doc """
  Makes a request with the given bearer token instead of the auth process's.

  For the rare endpoint that takes a different kind of token, such as ePOS
  registration, which takes a signed-in user's. It is a separate function,
  not an option of `request/3`, so a token cannot slip in through the
  options every resource function passes along. Takes the same options.
  """
  def request_with_token(token, method, path, opts) when is_binary(token) and token != "",
    do: send_request(method, path(path), opts, token, base_url: HTTP.base_url())

  @doc """
  Makes a POST that carries no `Idempotency-Key` header.

  For an endpoint whose spec does not document the header, such as DCC
  offers: sending it anyway could be refused, and a caller could not rely on
  a reused key to deduplicate. It is a separate function, not an option, so
  the key cannot be dropped from an endpoint that honours it. Takes the same
  options as `request/3`, less `:idempotency_key`, which it ignores.
  """
  def post_without_idempotency_key(path, opts) do
    authed_request(:post, path, opts, idempotency_key: false)
  end

  # Lower-case letters, digits and hyphens, as every Teya path is made of.
  @plain ~r{\A(/[a-z0-9-]+)+\z}
  @template ~r{\A(/([a-z0-9-]+|:[a-z_]+))+\z}

  @doc false
  # The one way a request path is built, so no value reaches a path without
  # being encoded. A path is either text with no values in it, such as
  # "/v2/checkout/sessions", or {template, values}, such as
  # {"/v2/checkout/sessions/:id", id: session_id}: each :name segment takes
  # its value from `values`, encoded as a single segment.
  #
  # Raises ArgumentError for a mistake in the calling code: a value with no
  # placeholder, a placeholder with no value, or text that is not a plain
  # path, which is how an interpolated value would show up.
  def path({template, values}) when is_binary(template) do
    plain!(template, @template)
    values = names!(values, template)

    {parts, used} =
      template
      |> String.split("/")
      |> Enum.map_reduce([], fn
        ":" <> name, used -> {segment(value!(values, name, template)), [name | used]}
        part, used -> {part, used}
      end)

    case Map.keys(values) -- used do
      [] -> Enum.join(parts, "/")
      extra -> raise ArgumentError, "#{template} has no placeholder for #{inspect(extra)}"
    end
  end

  def path(path) when is_binary(path), do: plain!(path, @plain)

  def path(other),
    do: raise(ArgumentError, "a path is text or {template, values}, got: #{inspect(other)}")

  @doc false
  # The full URL for a path, for requests that do not go through request/3,
  # such as the POSLink streams: on the host of the set of credentials whose
  # token the request will carry.
  # The path is built first, so a bad id raises before anything is asked of
  # the auth process.
  def url(path, set) do
    path = path(path)
    Auth.base_url(set) <> path
  end

  # The values as a map from name to value. Anything but a keyword list, or
  # a name given twice, is a mistake: a map or list of other shapes would
  # fail somewhere less clear, and a repeated name would quietly lose one of
  # its values. Nothing about a value is shown, as it may be a secret.
  defp names!(values, template) do
    if not Keyword.keyword?(values),
      do: raise(ArgumentError, "the values for #{template} must be a keyword list")

    names = Keyword.keys(values)

    if length(Enum.uniq(names)) != length(names),
      do: raise(ArgumentError, "a name is given twice in the values for #{template}")

    Map.new(values, fn {name, value} -> {Atom.to_string(name), value} end)
  end

  defp plain!(path, pattern) do
    if String.match?(path, pattern) do
      path
    else
      raise ArgumentError,
            "#{inspect(path)} is not a plain path: give any values as {template, values}"
    end
  end

  defp value!(values, name, template) do
    case Map.fetch(values, name) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "no value given for :#{name} in #{template}"
    end
  end

  # Encodes one segment of a request path, so a value holding "/", "?", "#"
  # or a space cannot change which endpoint is called. An empty one, from nil
  # say, raises: it would leave "//" in the path and call some other route.
  # So do "." and "..", which encoding leaves as they are, and which a proxy
  # or server may read as "this level" and "the level above".
  # Anything but text or an integer, a map say, raises too.
  defp segment(value) when is_integer(value), do: segment(Integer.to_string(value))

  defp segment(value) when is_binary(value) and value not in ["", ".", ".."],
    do: URI.encode(value, &URI.char_unreserved?/1)

  defp segment(value) do
    raise ArgumentError,
          "a request path segment must be text or an integer, and cannot be empty, " <>
            "\".\" or \"..\", got: #{inspect(value)}"
  end

  # A request with an auth process's token, which a retry asks for again.
  # The set of credentials is picked before anything else, so an unknown
  # name raises in the caller.
  defp authed_request(method, path, opts, settings) do
    path = path(path)
    set = Auth.set_for(opts, api(path))

    with {:ok, token} <- Auth.token(set) do
      settings = [credentials: set, base_url: Auth.base_url(set)] ++ settings
      send_request(method, path, opts, token, settings)
    end
  end

  # POSLink has credentials of its own, from ePOS registration. Everything
  # else uses the Developer Portal client.
  defp api("/poslink/" <> _rest), do: :poslink
  defp api(_path), do: :online

  # settings, for this library's callers only:
  # - :credentials — the token came from the auth process for this set
  #   (nil for the top-level credentials), so a retry asks it again
  # - :base_url — the host the token belongs to (see Auth.base_url/1)
  # - :retry — Req's :retry option, unless :req_options sets one
  # - :idempotency_key — false sends no Idempotency-Key, even on a POST
  defp send_request(method, path, opts, token, settings) do
    req_opts = Application.get_env(:teya, :req_options, [])

    req =
      [
        method: method,
        url: Keyword.fetch!(settings, :base_url) <> path,
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
      # Decoded here instead: see HTTP.decode_json/1.
      |> Keyword.put(:decode_body, false)
      # Set after the configured options, so an :auth among them cannot send
      # the wrong credentials to Teya in place of this token.
      |> Keyword.put(:auth, {:bearer, token})
      |> Req.new()
      # Any idempotency-key set in config is dropped, whatever the method:
      # one key there would mark every POST as a retry of the first, and it
      # means nothing on other methods. POST and PATCH get their own.
      |> Req.Request.delete_header("idempotency-key")
      |> Req.merge(headers: idempotency_headers(method, opts, settings))
      |> refresh_token_on_retry(settings)

    case Req.request(req) do
      {:ok, resp} -> resp |> HTTP.decode_json() |> result()
      {:error, reason} -> {:error, Error.from_reason(reason, "the request failed")}
    end
  end

  defp result({:ok, %{status: status} = resp}) when status in 200..299, do: {:ok, resp.body}
  defp result({:ok, resp}), do: {:error, Error.from_response(resp)}

  # A 2xx status says Teya acted on the request all the same.
  defp result({:unreadable, resp}), do: {:error, Error.unreadable(resp)}

  # Retries can run for minutes, past the life of the token the first
  # attempt was sent with, so each retry asks the auth process for its
  # current one. Req runs every request step again on a retry; the first run
  # only marks the request as sent. If the auth process has no token to
  # give, the retry goes with the old one and its answer says so.
  defp refresh_token_on_retry(req, settings) do
    case Keyword.fetch(settings, :credentials) do
      {:ok, set} ->
        req
        |> Req.Request.put_private(:teya_credentials, set)
        |> Req.Request.append_request_steps(teya_refresh_token: &refresh_token/1)

      :error ->
        req
    end
  end

  defp refresh_token(req) do
    with true <- Req.Request.get_private(req, :teya_sent, false),
         {:ok, token} <- Auth.token(Req.Request.get_private(req, :teya_credentials)) do
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

  defp idempotency_headers(method, opts, settings) do
    if method in [:post, :patch] and Keyword.get(settings, :idempotency_key, true),
      do: [{"idempotency-key", Keyword.get_lazy(opts, :idempotency_key, &generate_key/0)}],
      else: []
  end

  defp generate_key do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
