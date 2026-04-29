defmodule Teya.APICase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Teya.APICase
    end
  end

  # Stub the token endpoint for Auth's process, then allow Auth to access it.
  # stub must come before allow — allow copies the current stub into a location
  # accessible from Auth's GenServer process.
  setup do
    auth_pid = Process.whereis(Teya.Auth)

    if auth_pid do
      :sys.replace_state(auth_pid, fn state ->
        if state.refresh_timer_ref, do: Process.cancel_timer(state.refresh_timer_ref)
        %{state | token: nil, expires_at: nil, refresh_timer_ref: nil}
      end)
    end

    Req.Test.stub(Teya.Auth, fn conn ->
      Req.Test.json(conn, %{"access_token" => "test_access_token", "expires_in" => 3600})
    end)

    if auth_pid, do: Req.Test.allow(Teya.Auth, self(), auth_pid)

    :ok
  end

  @doc """
  Stubs the Teya API with the given handler for the current test process.

  The handler receives `%Plug.Conn{}` and must return it after sending a response.
  Token endpoint requests are handled automatically via the Auth stub set in setup.
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
