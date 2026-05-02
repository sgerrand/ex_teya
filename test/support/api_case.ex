defmodule Teya.APICase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Teya.APICase
    end
  end

  # Pre-seed a valid token directly into the Auth GenServer state. Resetting to
  # nil and stubbing the token endpoint races with stale `:refresh` messages
  # left by prior tests (e.g. retry timers from auth_test.exs): when a refresh
  # fires after the owning test process has exited, the `Req.Test` stub lookup
  # raises, crashing Auth and leaving a small window where `Process.whereis`
  # may return nil or a freshly restarted PID with no stub allowed.
  setup do
    auth_pid = Process.whereis(Teya.Auth)

    if auth_pid do
      :sys.replace_state(auth_pid, fn state ->
        if state.refresh_timer_ref, do: Process.cancel_timer(state.refresh_timer_ref)

        %{
          state
          | token: "test_access_token",
            expires_at: System.monotonic_time(:second) + 3600,
            refresh_timer_ref: nil,
            retry_count: 0
        }
      end)
    end

    :ok
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

  @doc """
  Stubs the DCC endpoint with the given handler for the current test process.

  Use instead of `stub_api/1` for `Teya.DCC.quote/1` calls, which do not go
  through the authenticated client.
  """
  def stub_dcc(handler) when is_function(handler, 1) do
    Req.Test.stub(Teya.DCC, handler)
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
