defmodule Teya.Auth do
  @moduledoc false
  use GenServer
  require Logger

  alias Teya.Config

  @refresh_margin_seconds 30
  @base_retry_delay_ms 1_000
  @max_retry_delay_ms 60_000

  defstruct [:config, :token, :expires_at, :refresh_timer_ref, retry_count: 0]

  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Returns `{:ok, access_token}` from the cache, fetching one from the token endpoint if needed."
  def token do
    GenServer.call(__MODULE__, :token)
  end

  @impl true
  def init(%Config{} = config) do
    {:ok, %__MODULE__{config: config}}
  end

  @impl true
  def handle_call(:token, _from, state) do
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

        {:noreply,
         %{
           state
           | token: token,
             expires_at: expires_at,
             retry_count: 0,
             refresh_timer_ref: schedule_refresh(state, expires_at)
         }}

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
    if System.monotonic_time(:second) + @refresh_margin_seconds >= state.expires_at do
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

        {:ok,
         %{
           state
           | token: token,
             expires_at: expires_at,
             retry_count: 0,
             refresh_timer_ref: schedule_refresh(state, expires_at)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_token(%Config{} = config) do
    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => config.client_id,
        "client_secret" => config.client_secret,
        "scope" => Enum.join(config.scopes, " ")
      })

    req_opts =
      Application.get_env(
        :teya,
        :auth_req_options,
        Application.get_env(:teya, :req_options, [])
      )

    opts =
      [
        body: body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        receive_timeout: 10_000
      ] ++ req_opts

    case Req.post(config.token_url, opts) do
      {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}} ->
        {:ok, token, System.monotonic_time(:second) + expires_in}

      {:ok, resp} ->
        {:error, resp}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_refresh(%{refresh_timer_ref: ref}, expires_at) do
    if ref, do: Process.cancel_timer(ref)
    delay = max(expires_at - System.monotonic_time(:second) - @refresh_margin_seconds, 0)
    Process.send_after(self(), :refresh, :timer.seconds(delay))
  end

  defp retry_delay_ms(count) do
    delay = @base_retry_delay_ms * trunc(:math.pow(2, count))
    min(delay, @max_retry_delay_ms)
  end
end
