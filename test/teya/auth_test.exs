defmodule Teya.AuthTest do
  use ExUnit.Case, async: false

  setup do
    auth_pid = Process.whereis(Teya.Auth)
    # Reset cached token to force a fresh fetch on each test
    :sys.replace_state(auth_pid, fn state ->
      if state.refresh_timer_ref, do: Process.cancel_timer(state.refresh_timer_ref)
      %{state | token: nil, expires_at: nil, refresh_timer_ref: nil}
    end)

    %{auth_pid: auth_pid}
  end

  # Stubs the auth token endpoint and allows the Auth GenServer process to access it.
  # stub must come before allow.
  defp stub_auth(auth_pid, handler) do
    Req.Test.stub(Teya.Auth, handler)
    Req.Test.allow(Teya.Auth, self(), auth_pid)
  end

  describe "token/0" do
    test "fetches an OAuth token from the token endpoint", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/connect/token"
        Req.Test.json(conn, %{"access_token" => "fresh_token", "expires_in" => 3600})
      end)

      assert {:ok, "fresh_token"} = Teya.Auth.token()
    end

    test "caches the token on subsequent calls", %{auth_pid: auth_pid} do
      call_count = :counters.new(1, [])

      stub_auth(auth_pid, fn conn ->
        :counters.add(call_count, 1, 1)
        Req.Test.json(conn, %{"access_token" => "cached_token", "expires_in" => 3600})
      end)

      assert {:ok, "cached_token"} = Teya.Auth.token()
      assert {:ok, "cached_token"} = Teya.Auth.token()
      assert :counters.get(call_count, 1) == 1
    end

    test "returns error when token endpoint responds with non-200", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "invalid_client"})
      end)

      assert {:error, _} = Teya.Auth.token()
    end
  end
end
