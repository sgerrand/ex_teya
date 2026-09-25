defmodule Teya.Auth do
  @moduledoc false
  use GenServer
  require Logger

  alias Teya.{Config, Error, HTTP}

  @refresh_margin_seconds 30
  @base_retry_delay_ms 1_000
  @max_retry_delay_ms 60_000

  # margin is how long before expiry this token is refreshed. It shrinks for a
  # token that lives less than twice the usual margin.
  defstruct [
    :config,
    :token,
    :expires_at,
    :refresh_timer_ref,
    retry_count: 0,
    margin: @refresh_margin_seconds
  ]

  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  # How long a caller waits for a token. The token request's own timeouts are
  # kept inside it, so a slow but working token server is not cut off. Without
  # it, GenServer.call's 5-second default made a slow token request crash the
  # caller instead of returning an error.
  @default_token_timeout_ms 15_000

  # The token's lifetime when the reply does not give a usable one. RFC 6749
  # only recommends expires_in, so a server may leave it out.
  @default_token_lifetime_seconds 300

  @doc """
  Returns `{:ok, access_token}` from the cache, fetching one from the token
  endpoint if needed. Returns `{:error, %Teya.Error{}}` if that takes longer
  than `:token_timeout_ms`.
  """
  def token do
    timeout = token_timeout()
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(__MODULE__, {:token, deadline}, timeout)
  catch
    # A fetch already under way carries on and caches its token for the next
    # caller.
    :exit, {:timeout, _call} -> {:error, timed_out()}
  end

  defp timed_out, do: %Error{message: "timed out waiting for an access token"}

  defp token_timeout,
    do: Application.get_env(:teya, :token_timeout_ms, @default_token_timeout_ms)

  @impl true
  def init(%Config{} = config) do
    {:ok, %__MODULE__{config: config}}
  end

  # A request reached only after its caller has given up is answered without
  # fetching. Otherwise, while a fetch is failing, every caller queued behind
  # it would set off another fetch, one after another, for nobody.
  @impl true
  def handle_call({:token, deadline}, _from, state) do
    if System.monotonic_time(:millisecond) >= deadline,
      do: {:reply, {:error, timed_out()}, state},
      else: reply_with_token(state)
  end

  defp reply_with_token(state) do
    case ensure_valid_token(state) do
      {:ok, new_state} -> {:reply, {:ok, new_state.token}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
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
        {:noreply, %{state | refresh_timer_ref: ref, retry_count: state.retry_count + 1}}
    end
  end

  defp ensure_valid_token(%{token: nil} = state), do: do_fetch(state)

  defp ensure_valid_token(state) do
    if System.monotonic_time(:second) + state.margin >= state.expires_at do
      do_fetch(state)
    else
      {:ok, state}
    end
  end

  defp do_fetch(state) do
    case fetch_token(state.config) do
      {:ok, token, expires_at} ->
        expires_in = expires_at - System.monotonic_time(:second)
        Logger.debug("Teya.Auth: token fetched, expires in #{expires_in}s")
        {:ok, store_token(state, token, expires_at)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A token that lives less than twice the usual margin is refreshed halfway
  # through its life instead. With the full margin it would already count as
  # due, and be fetched again straight away, over and over.
  defp store_token(state, token, expires_at) do
    lifetime = expires_at - System.monotonic_time(:second)
    margin = min(@refresh_margin_seconds, div(lifetime, 2))

    %{
      state
      | token: token,
        expires_at: expires_at,
        margin: margin,
        retry_count: 0,
        refresh_timer_ref: schedule_refresh(state, expires_at, margin)
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

    # Connecting and waiting for the reply each get at most half of the time a
    # caller waits, whatever the options say, so the request always finishes
    # before its caller gives up. The options may be the ones for API calls,
    # with timeouts meant for those.
    budget = div(token_timeout(), 2)

    req =
      [method: :post, url: config.token_url, body: body, user_agent: HTTP.user_agent()]
      |> Keyword.merge(HTTP.options(:auth_req_options))
      |> Keyword.update(:receive_timeout, budget, &min(&1, budget))
      |> Keyword.update(:connect_options, [timeout: budget], fn connect ->
        Keyword.update(connect, :timeout, budget, &min(&1, budget))
      end)
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

  defp lifetime(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  defp lifetime(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {seconds, ""} when seconds > 0 -> seconds
      _other -> @default_token_lifetime_seconds
    end
  end

  defp lifetime(_seconds), do: @default_token_lifetime_seconds

  defp schedule_refresh(%{refresh_timer_ref: ref}, expires_at, margin) do
    if ref, do: Process.cancel_timer(ref)
    delay = max(expires_at - System.monotonic_time(:second) - margin, 0)
    Process.send_after(self(), :refresh, :timer.seconds(delay))
  end

  defp retry_delay_ms(count) do
    delay = @base_retry_delay_ms * trunc(:math.pow(2, count))
    min(delay, @max_retry_delay_ms)
  end
end
