defmodule Teya.POSLink.SubscribeCase do
  @moduledoc false

  # Test case template for POSLink streaming (subscribe) tests.
  #
  # Unlike Teya.APICase, this module does NOT reset the auth token to nil or
  # set up the Teya.Auth HTTP stub. Instead, it pre-seeds a valid token
  # directly into the GenServer state. This avoids a race condition where a
  # Task spawned by subscribe/2 outlives the test process: if the token is
  # already cached, Auth.token/0 returns immediately without making any HTTP
  # request, so there is no stub lookup that could fail after the test process
  # exits.

  use ExUnit.CaseTemplate

  setup do
    auth_pid = Process.whereis(Teya.Auth)

    if auth_pid do
      :sys.replace_state(auth_pid, fn state ->
        if state.refresh_timer_ref, do: Process.cancel_timer(state.refresh_timer_ref)

        %{
          state
          | token: "test_access_token",
            expires_at: System.monotonic_time(:second) + 3600,
            refresh_timer_ref: nil
        }
      end)
    end

    :ok
  end

  @doc """
  Stubs the POSLink SSE endpoint with the given handler for the current test process.

  The handler receives `%Plug.Conn{}` and must return it after sending a response.
  """
  def stub_sse(handler) when is_function(handler, 1) do
    Req.Test.stub(Teya.POSLink.Subscriber, handler)
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

  using do
    quote do
      import Teya.POSLink.SubscribeCase
    end
  end
end
