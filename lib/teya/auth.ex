defmodule Teya.Auth do
  @moduledoc false
  use GenServer
  require Logger

  alias Teya.{Config, Error, HTTP}

  @refresh_margin_seconds 30
  @base_retry_delay_ms 1_000
  @max_retry_delay_ms 60_000

  # usable_until is when the cached token stops being handed out, a little
  # before it expires. failed_at and failure hold the last failed fetch, which
  # callers share for a moment rather than each setting off another.
  defstruct [
    :config,
    :token,
    :expires_at,
    :usable_until,
    :refresh_timer_ref,
    :failed_at,
    :failure,
    retry_count: 0
  ]

  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  # How long a caller waits for a token. It is longer than the token request's
  # own 10-second default, so a slow but working token server is not cut off.
  # Without it, GenServer.call's 5-second default made a slow token request
  # crash the caller instead of returning an error.
  @default_token_timeout_ms 15_000

  # The token's lifetime when the reply does not give a usable one. RFC 6749
  # only recommends expires_in, so a server may leave it out.
  @default_token_lifetime_seconds 300

  # A token is handed out only until this long before it expires, so a request
  # made with it does not reach Teya just after it has run out. The expiry is
  # counted from when the reply arrived, a little after the server issued it.
  @expiry_skew_seconds 5

  # After a fetch fails, callers in the next second are given that failure
  # rather than each sending the token server a request of its own. Without
  # it, a burst of calls while the server was refusing every request — after
  # credentials were rotated, say — sent one request per call.
  @failure_hold_ms 1_000

  # Process.send_after/3 takes at most 2^32 - 1 milliseconds, about 49 days.
  @max_timer_ms 4_294_967_295

  @doc """
  Returns `{:ok, access_token}` from the cache, fetching one from the token
  endpoint if needed. Returns `{:error, %Teya.Error{}}` if that takes longer
  than `:token_timeout_ms`.
  """
  def token do
    timeout = token_timeout()
    GenServer.call(__MODULE__, {:token, deadline(timeout)}, timeout)
  catch
    # A fetch already under way carries on and caches its token for the next
    # caller.
    :exit, {:timeout, _call} -> {:error, timed_out()}
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp timed_out, do: %Error{message: "timed out waiting for an access token"}

  defp token_timeout do
    case Application.get_env(:teya, :token_timeout_ms, @default_token_timeout_ms) do
      timeout when timeout == :infinity or (is_integer(timeout) and timeout > 0) -> timeout
      _other -> @default_token_timeout_ms
    end
  end

  @impl true
  def init(%Config{} = config) do
    {:ok, %__MODULE__{config: config}}
  end

  # A request reached only after its caller has given up is answered without
  # fetching. Otherwise, while a fetch is failing, every caller queued behind
  # it would set off another fetch, one after another, for nobody. An
  # :infinity deadline is never passed: any number is less than any atom.
  @impl true
  def handle_call({:token, deadline}, _from, state) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:reply, {:error, timed_out()}, state}
    else
      case ensure_valid_token(state) do
        {:ok, state} -> {:reply, {:ok, state.token}, state}
        {:error, reason, state} -> {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    Logger.debug("Teya.Auth: proactive token refresh started")

    case fetch_token(state.config) do
      {:ok, token, expires_at} ->
        expires_in = expires_at - System.monotonic_time(:second)
        Logger.info("Teya.Auth: token refreshed, expires in #{expires_in}s")
        {:noreply, store_token(state, token, expires_at)}

      {:error, reason} ->
        delay_ms = retry_delay_ms(state.retry_count)

        Logger.warning(
          "Teya.Auth: token refresh failed (#{inspect(reason)}), retrying in #{delay_ms}ms"
        )

        ref = Process.send_after(self(), :refresh, delay_ms)

        {:noreply,
         %{
           record_failure(state, reason)
           | refresh_timer_ref: ref,
             retry_count: state.retry_count + 1
         }}
    end
  end

  # The cached token is used until shortly before it expires. Renewing it
  # before then is the background refresh's job, which retries with backoff
  # when it fails. Fetching here any sooner would make every caller in the last
  # seconds of a token's life wait on a fetch of its own, and, while the token
  # server was down, hand them an error in place of a token that still worked.
  defp ensure_valid_token(state) do
    if state.token && System.monotonic_time(:second) < (state.usable_until || state.expires_at),
      do: {:ok, state},
      else: fetch(state)
  end

  defp fetch(state) do
    if recently_failed?(state) do
      {:error, state.failure, state}
    else
      case fetch_token(state.config) do
        {:ok, token, expires_at} ->
          expires_in = expires_at - System.monotonic_time(:second)
          Logger.debug("Teya.Auth: token fetched, expires in #{expires_in}s")
          {:ok, store_token(state, token, expires_at)}

        {:error, reason} ->
          {:error, reason, record_failure(state, reason)}
      end
    end
  end

  defp recently_failed?(%{failed_at: nil}), do: false

  defp recently_failed?(%{failed_at: failed_at}),
    do: System.monotonic_time(:millisecond) - failed_at < @failure_hold_ms

  defp record_failure(state, reason),
    do: %{state | failed_at: System.monotonic_time(:millisecond), failure: reason}

  defp store_token(state, token, expires_at) do
    lifetime = expires_at - System.monotonic_time(:second)

    %{
      state
      | token: token,
        expires_at: expires_at,
        usable_until: expires_at - min(@expiry_skew_seconds, div(lifetime, 4)),
        failed_at: nil,
        failure: nil,
        retry_count: 0,
        refresh_timer_ref: schedule_refresh(state, lifetime)
    }
  end

  defp fetch_token(%Config{} = config) do
    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => config.client_id,
        "client_secret" => config.client_secret,
        "scope" => Enum.join(config.scopes, " ")
      })

    req =
      [
        method: :post,
        url: config.token_url,
        body: body,
        user_agent: HTTP.user_agent(),
        receive_timeout: 10_000
      ]
      |> Keyword.merge(HTTP.options(:auth_req_options))
      |> Req.new()
      # The body is a form whatever the options say about content types. They
      # fall back to :req_options, which are meant for JSON API calls.
      |> Req.merge(headers: [{"content-type", "application/x-www-form-urlencoded"}])

    case Req.request(req) do
      {:ok, %{status: status, body: %{"access_token" => token} = body}}
      when status in 200..299 and is_binary(token) ->
        {:ok, token, System.monotonic_time(:second) + lifetime(body["expires_in"])}

      # A success whose reply cannot be read may still hold a live token, and
      # a failed refresh is logged, so none of the body goes into the error.
      {:ok, %{status: status}} when status in 200..299 ->
        {:error, %Error{status: status, message: "the token endpoint's reply could not be read"}}

      {:ok, resp} ->
        {:error, Error.from_oauth_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A lifetime of 0 is the server saying not to reuse the token, so it is
  # kept as 0 rather than read as missing: the caller gets this token, and the
  # next one fetches a new one.
  defp lifetime(seconds) when is_integer(seconds) and seconds >= 0, do: seconds

  defp lifetime(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {seconds, ""} when seconds >= 0 -> seconds
      _other -> @default_token_lifetime_seconds
    end
  end

  defp lifetime(_seconds), do: @default_token_lifetime_seconds

  # A token is refreshed ahead of expiry by the usual margin, or halfway
  # through its life if it lives less than twice that. A token too short-lived
  # for either — a second or less — gets no refresh ahead of time: it would be
  # refreshed in a loop, so a new one is fetched when the next caller needs it.
  # A very long-lived one is refreshed after at most the longest a timer can
  # wait, which only means fetching its replacement early.
  defp schedule_refresh(%{refresh_timer_ref: ref}, lifetime) do
    if ref, do: Process.cancel_timer(ref)
    margin = min(@refresh_margin_seconds, div(lifetime, 2))

    if margin > 0 do
      delay_ms = min(:timer.seconds(lifetime - margin), @max_timer_ms)
      Process.send_after(self(), :refresh, delay_ms)
    end
  end

  # The delay doubles from a second up to a minute. The doubling stops once it
  # passes the cap: an unbounded power of two overflows a float after 1024
  # failures, about 17 hours of them, and would crash the process.
  @max_retry_doublings 6

  defp retry_delay_ms(count) do
    delay = @base_retry_delay_ms * Integer.pow(2, min(count, @max_retry_doublings))
    min(delay, @max_retry_delay_ms)
  end
end
