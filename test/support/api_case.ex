defmodule Teya.APICase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Teya.APICase
    end
  end

  # Pre-seed a valid token directly into the Auth GenServer state. Resetting to
  # nil and stubbing the token endpoint races with stale refresh messages
  # left by prior tests (e.g. retry timers from auth_test.exs): when a refresh
  # fires after the owning test process has exited, the `Req.Test` stub lookup
  # raises, crashing Auth and leaving a small window where `Process.whereis`
  # may return nil or a freshly restarted PID with no stub allowed.
  setup do
    if auth_pid = Process.whereis(Teya.Auth), do: reset_auth(auth_pid, "test_access_token")
    :ok
  end

  @doc """
  Resets the auth process's state: no fetch, waiters, failure or refresh
  timer, and `token` cached for an hour, or no token when it is nil.
  """
  def reset_auth(auth_pid, token \\ nil) do
    :sys.replace_state(auth_pid, fn state ->
      %{
        cancel_refresh(state)
        | token: token,
          usable_until: if(token, do: System.monotonic_time(:second) + 3600),
          failure: nil,
          fetch: nil,
          waiters: [],
          retry_count: 0
      }
    end)

    :ok
  end

  @doc """
  Cancels the refresh timer an auth process's `state` holds, if any, and
  clears it, so it cannot fire into a later test. For use inside
  `:sys.replace_state/2`.
  """
  def cancel_refresh(state) do
    if state.refresh_timer_ref, do: Process.cancel_timer(state.refresh_timer_ref)
    %{state | refresh_timer_ref: nil}
  end

  @doc """
  Stubs the Teya API with the given handler for the current test process.

  The handler receives `%Plug.Conn{}` and must return it after sending a response.
  The Auth GenServer is pre-seeded with a valid token in setup, so no token
  endpoint stub is required.
  """
  def stub_api(api_handler) when is_function(api_handler, 1) do
    Req.Test.stub(Teya.Client, api_handler)
  end

  @doc "Sends a JSON response with the given status and body map."
  def json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(body)
  end

  @doc "Sends a Teya-style error response."
  def error_response(conn, status, code, description) do
    json_response(conn, status, %{"code" => code, "description" => description})
  end
end
