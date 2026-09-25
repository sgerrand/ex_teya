defmodule Teya.Auth do
  @moduledoc false
  use GenServer
  require Logger

  alias Teya.{Config, Error, HTTP}

  @refresh_margin_seconds 30
  @base_retry_delay_ms 1_000
  @max_retry_delay_ms 60_000

  # The token request runs in a task, never in this process, so a caller with
  # a usable token cached is answered at once, whatever a fetch is doing.
  #
  # fetch is the task under way, if any, and whether it is a background
  # refresh. waiters are the callers who need a token that is not cached;
  # the one fetch answers them all. usable_until is when the cached token
  # stops being handed out, a little before it expires. failed_at and failure
  # hold the last failed fetch, which callers share for a moment rather than
  # each setting off another.
  defstruct [
    :config,
    :token,
    :expires_at,
    :usable_until,
    :refresh_timer_ref,
    :fetch,
    :failed_at,
    :failure,
    waiters: [],
    retry_count: 0
  ]

  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  # How long a caller waits for a token. It is longer than the token request's
  # own 10-second default, so a slow but working token server is not cut off.
  @default_token_timeout_ms 15_000

  # The token's lifetime when the reply does not give a usable one. RFC 6749
  # only recommends expires_in, so a server may leave it out.
  @default_token_lifetime_seconds 300

  # A token is handed out only until this long before it expires, so a request
  # made with it does not reach Teya just after it has run out. The expiry is
  # counted from when the reply arrived, a little after the server issued it.
  @expiry_skew_seconds 5

  # After a fetch fails, callers in the next second are given that failure
  # rather than setting off another fetch straight away. Without it, a burst
  # of calls while the server was refusing every request — after credentials
  # were rotated, say — would fetch again and again.
  @failure_hold_ms 1_000

  # Process.send_after/3 takes at most 2^32 - 1 milliseconds, about 49 days.
  @max_timer_ms 4_294_967_295

  @doc """
  Returns `{:ok, access_token}` from the cache, fetching one from the token
  endpoint if needed. Returns `{:error, %Teya.Error{}}` if that takes longer
  than `:token_timeout_ms`.
  """
  def token do
    GenServer.call(__MODULE__, :token, token_timeout())
  catch
    # The fetch carries on and caches its token for the next caller.
    :exit, {:timeout, _call} -> {:error, timed_out()}
  end

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

  @impl true
  def handle_call(:token, from, state) do
    cond do
      usable?(state) -> {:reply, {:ok, state.token}, state}
      recently_failed?(state) -> {:reply, {:error, state.failure}, state}
      true -> {:noreply, start_fetch(%{state | waiters: [from | state.waiters]}, :call)}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    Logger.debug("Teya.Auth: proactive token refresh started")
    {:noreply, start_fetch(state, :refresh)}
  end

  def handle_info({ref, result}, %{fetch: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_fetch(state, result)}
  end

  # The task died before it answered. Its exit reason is not passed on: it
  # could hold the request, and with it the client secret.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{fetch: %{ref: ref}} = state) do
    {:noreply, finish_fetch(state, {:error, %Error{message: "the token request failed"}})}
  end

  # A reply or exit from a fetch this process no longer follows, such as one
  # started before its state was reset.
  def handle_info(_message, state), do: {:noreply, state}

  # The cached token is used until shortly before it expires. Renewing it
  # before then is the background refresh's job, which retries with backoff
  # when it fails, so a failing refresh never costs a caller a token that
  # still works.
  defp usable?(%{token: token, usable_until: until})
       when is_binary(token) and is_integer(until),
       do: System.monotonic_time(:second) < until

  defp usable?(_state), do: false

  defp recently_failed?(%{failed_at: nil}), do: false

  defp recently_failed?(%{failed_at: failed_at}),
    do: System.monotonic_time(:millisecond) - failed_at < @failure_hold_ms

  # One fetch at a time: a caller who arrives while one is under way waits
  # for it, whether it was started by another caller or by the refresh timer.
  defp start_fetch(%{fetch: nil} = state, kind) do
    config = state.config
    task = Task.Supervisor.async_nolink(Teya.TaskSupervisor, fn -> fetch_token(config) end)
    %{state | fetch: %{ref: task.ref, kind: kind}}
  end

  defp start_fetch(state, _kind), do: state

  defp finish_fetch(state, {:ok, token, expires_at}) do
    expires_in = expires_at - System.monotonic_time(:second)
    Logger.debug("Teya.Auth: token fetched, expires in #{expires_in}s")
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, token}))
    %{store_token(state, token, expires_at) | fetch: nil, waiters: []}
  end

  defp finish_fetch(state, {:error, reason}) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, reason}))
    retry? = state.fetch.kind == :refresh or state.token != nil

    state = %{
      state
      | fetch: nil,
        waiters: [],
        failed_at: System.monotonic_time(:millisecond),
        failure: reason
    }

    if retry?, do: schedule_retry(state, reason), else: state
  end

  # A failed refresh, or any failed fetch while a token is cached, means the
  # token is due or overdue for renewal, so keep trying in the background,
  # with growing gaps. A caller's fetch with no token cached is not retried:
  # the next caller fetches again.
  defp schedule_retry(state, reason) do
    delay_ms = retry_delay_ms(state.retry_count)

    Logger.warning(
      "Teya.Auth: token refresh failed (#{inspect(reason)}), retrying in #{delay_ms}ms"
    )

    cancel_timer(state.refresh_timer_ref)
    ref = Process.send_after(self(), :refresh, delay_ms)
    %{state | refresh_timer_ref: ref, retry_count: state.retry_count + 1}
  end

  defp store_token(state, token, expires_at) do
    lifetime = expires_at - System.monotonic_time(:second)
    cancel_timer(state.refresh_timer_ref)

    %{
      state
      | token: token,
        expires_at: expires_at,
        usable_until: expires_at - min(@expiry_skew_seconds, div(lifetime, 4)),
        failed_at: nil,
        failure: nil,
        retry_count: 0,
        refresh_timer_ref: schedule_refresh(lifetime)
    }
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

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
  defp lifetime(seconds) when is_float(seconds) and seconds >= 0, do: trunc(seconds)

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
  defp schedule_refresh(lifetime) do
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
