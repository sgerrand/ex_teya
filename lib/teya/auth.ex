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
  # fetch is the task under way, if any: its monitor, its pid, whether it is a
  # background refresh, and the timer that ends it if it runs too long.
  # waiters are the callers who need a token that is not cached, each with
  # the time it stops waiting; the one fetch answers them all. usable_until is when the cached token stops being
  # handed out, a little before expires_at. refresh_tag marks the refresh
  # timer that is current, so a stale one that already fired is ignored.
  # failed_at and failure hold the last failed fetch, which callers share for
  # a moment rather than each setting off another.
  defstruct [
    :config,
    :token,
    :expires_at,
    :usable_until,
    :refresh_timer_ref,
    :refresh_tag,
    :fetch,
    :failed_at,
    :failure,
    waiters: [],
    retry_count: 0
  ]

  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  # How long a caller waits for a token, and how long a fetch may run before
  # it is stopped. It is longer than the token request's own 10-second reply
  # timeout, so a slow but working token server is not cut off. A fetch has a
  # limit even when callers will wait for ever, since one that hung would
  # otherwise keep every later caller waiting on it.
  @default_token_timeout_ms 15_000
  @unlimited_fetch_ms 60_000

  # The fetch is stopped a little after its callers give up, never at the same
  # moment, so a caller always hears that it timed out, not a race between
  # its own timeout and the fetch's.
  @fetch_grace_ms 1_000

  # The token's lifetime when the reply does not give a usable one. RFC 6749
  # only recommends expires_in, so a server may leave it out.
  @default_token_lifetime_seconds 300

  # A token is handed out only until this long before it expires, so a request
  # made with it does not reach Teya just after it has run out. The expiry is
  # counted from when the reply arrived, a little after the server issued it.
  # A token that lives no longer than this is given only to the callers who
  # waited for it, and never cached.
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
  endpoint if needed. Returns `{:error, %Teya.Error{}}` if that fails, takes
  longer than `:token_timeout_ms`, or the auth process is not running.
  """
  def token do
    timeout = token_timeout()
    GenServer.call(__MODULE__, {:token, gives_up_at(timeout)}, timeout)
  catch
    # A fetch already under way carries on and caches its token for the next
    # caller.
    :exit, {:timeout, _call} -> {:error, timed_out()}
    # Not running — no :client_id is configured, or it is restarting.
    :exit, _reason -> {:error, %Error{message: "the auth process is not available"}}
  end

  defp timed_out, do: %Error{message: "timed out waiting for an access token"}

  defp gives_up_at(:infinity), do: :infinity
  defp gives_up_at(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp token_timeout do
    case Application.get_env(:teya, :token_timeout_ms, @default_token_timeout_ms) do
      timeout when timeout == :infinity or (is_integer(timeout) and timeout > 0) -> timeout
      _other -> @default_token_timeout_ms
    end
  end

  defp fetch_limit do
    case token_timeout() do
      :infinity -> @unlimited_fetch_ms
      timeout -> timeout + @fetch_grace_ms
    end
  end

  @impl true
  def init(%Config{} = config) do
    {:ok, %__MODULE__{config: config}}
  end

  @impl true
  def handle_call({:token, gives_up_at}, from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      usable?(state) ->
        {:reply, {:ok, state.token}, state}

      recently_failed?(state) ->
        {:reply, {:error, state.failure}, state}

      # Its caller has already given up, so do not fetch for it.
      gives_up_at <= now ->
        {:reply, {:error, timed_out()}, state}

      true ->
        waiters = [{from, gives_up_at} | still_waiting(state.waiters, now)]
        {:noreply, start_fetch(%{state | waiters: waiters}, :call)}
    end
  end

  # A caller that has given up stays in the list until someone looks, so
  # each new caller clears out those whose wait is over. The list then holds
  # only callers still waiting, however long a fetch takes and however many
  # short-lived callers come and go meanwhile. :infinity is later than any
  # time: every atom sorts after every number.
  defp still_waiting(waiters, now),
    do: Enum.filter(waiters, fn {_from, gives_up_at} -> gives_up_at > now end)

  @impl true
  def handle_info({:refresh, tag}, %{refresh_tag: tag} = state) do
    Logger.debug("Teya.Auth: proactive token refresh started")
    {:noreply, start_fetch(%{state | refresh_tag: nil}, :refresh)}
  end

  # A refresh timer that fired after a newer one replaced it, its message
  # already sent when the timer was cancelled.
  def handle_info({:refresh, _stale_tag}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{fetch: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_fetch(state, result)}
  end

  # The task died without answering, killed from outside, say. It catches its
  # own errors, so this is rare.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{fetch: %{ref: ref}} = state) do
    {:noreply, finish_fetch(state, {:error, %Error{message: "the token request failed"}})}
  end

  def handle_info({:fetch_timeout, ref}, %{fetch: %{ref: ref, pid: pid}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    {:noreply, finish_fetch(state, {:error, %Error{message: "the token request took too long"}})}
  end

  # A reply, exit or time limit from a fetch this process no longer follows,
  # such as one that finished just before its limit, or one started before
  # its state was reset.
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:fetch_timeout, _ref}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.warning("Teya.Auth: unexpected message #{inspect(message)}")
    {:noreply, state}
  end

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
    task = Task.Supervisor.async_nolink(Teya.TaskSupervisor, fn -> safe_fetch(config) end)
    timer = Process.send_after(self(), {:fetch_timeout, task.ref}, fetch_limit())
    %{state | fetch: %{ref: task.ref, pid: task.pid, kind: kind, timer: timer}}
  end

  defp start_fetch(state, _kind), do: state

  # An exception or exit inside the fetch is turned into an error here, in the
  # task. Left to crash the task, it would be logged as a crash report, and
  # its details could include the request and, with it, the client secret.
  defp safe_fetch(config) do
    fetch_token(config)
  catch
    # Raised errors, exits and throws alike.
    _kind, _reason -> {:error, %Error{message: "the token request failed"}}
  end

  defp finish_fetch(%{fetch: fetch} = state, {:ok, token, expires_at}) do
    lifetime = expires_at - System.monotonic_time(:second)

    if fetch.kind == :refresh,
      do: Logger.info("Teya.Auth: token refreshed, expires in #{lifetime}s"),
      else: Logger.debug("Teya.Auth: token fetched, expires in #{lifetime}s")

    Process.cancel_timer(fetch.timer)
    reply_all(state.waiters, {:ok, token})
    %{store_token(state, token, expires_at, lifetime) | fetch: nil, waiters: []}
  end

  defp finish_fetch(%{fetch: fetch} = state, {:error, reason}) do
    Process.cancel_timer(fetch.timer)
    reply_all(state.waiters, {:error, reason})
    retry? = fetch.kind == :refresh or state.token != nil

    state = %{
      state
      | fetch: nil,
        waiters: [],
        failed_at: System.monotonic_time(:millisecond),
        failure: reason
    }

    if retry?, do: schedule_retry(state, reason), else: state
  end

  defp reply_all(waiters, reply),
    do: Enum.each(waiters, fn {from, _gives_up_at} -> GenServer.reply(from, reply) end)

  # A failed refresh, or any failed fetch while a token is cached, means the
  # token is due or overdue for renewal, so keep trying in the background,
  # with growing gaps. A caller's fetch with no token cached is not retried:
  # the next caller fetches again.
  defp schedule_retry(state, reason) do
    delay_ms = retry_delay_ms(state.retry_count)

    Logger.warning(
      "Teya.Auth: token refresh failed (#{inspect(reason)}), retrying in #{delay_ms}ms"
    )

    %{schedule(state, delay_ms) | retry_count: state.retry_count + 1}
  end

  defp store_token(state, token, expires_at, lifetime) do
    state = %{
      state
      | token: token,
        expires_at: expires_at,
        usable_until: expires_at - @expiry_skew_seconds,
        failed_at: nil,
        failure: nil,
        retry_count: 0
    }

    schedule_refresh(state, lifetime)
  end

  # A token is refreshed ahead of expiry by the usual margin, or halfway
  # through its life if it lives less than twice that. A token too short-lived
  # for either — a second or less — gets no refresh ahead of time: it would be
  # refreshed in a loop, so a new one is fetched when the next caller needs it.
  # A very long-lived one is refreshed after at most the longest a timer can
  # wait, which only means fetching its replacement early.
  defp schedule_refresh(state, lifetime) do
    margin = min(@refresh_margin_seconds, div(lifetime, 2))

    if margin > 0,
      do: schedule(state, min(:timer.seconds(lifetime - margin), @max_timer_ms)),
      else: cancel_refresh(state)
  end

  # A fresh tag for each timer: cancelling a timer does not take back a
  # message it has already sent, so the tag is what tells a stale refresh
  # from the current one.
  defp schedule(state, delay_ms) do
    state = cancel_refresh(state)
    tag = make_ref()
    ref = Process.send_after(self(), {:refresh, tag}, delay_ms)
    %{state | refresh_timer_ref: ref, refresh_tag: tag}
  end

  defp cancel_refresh(%{refresh_timer_ref: nil} = state), do: %{state | refresh_tag: nil}

  defp cancel_refresh(%{refresh_timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | refresh_timer_ref: nil, refresh_tag: nil}
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
  defp lifetime(seconds) when is_float(seconds) and seconds >= 0, do: trunc(seconds)

  defp lifetime(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {seconds, ""} when seconds >= 0 -> seconds
      _other -> @default_token_lifetime_seconds
    end
  end

  defp lifetime(_seconds), do: @default_token_lifetime_seconds

  # The delay doubles from a second up to a minute. The doubling stops once it
  # passes the cap: an unbounded power of two overflows a float after 1024
  # failures, about 17 hours of them, and would crash the process.
  @max_retry_doublings 6

  defp retry_delay_ms(count) do
    delay = @base_retry_delay_ms * Integer.pow(2, min(count, @max_retry_doublings))
    min(delay, @max_retry_delay_ms)
  end
end
