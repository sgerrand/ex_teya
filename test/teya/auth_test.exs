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

    test "returns error on token endpoint transport failure", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} = Teya.Auth.token()
    end

    test "re-fetches when cached token is near expiry", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "fresh_token", "expires_in" => 3600})
      end)

      :sys.replace_state(auth_pid, fn state ->
        %{state | token: "old_token", expires_at: System.monotonic_time(:second) - 1}
      end)

      assert {:ok, "fresh_token"} = Teya.Auth.token()
    end
  end

  describe "proactive refresh" do
    test "updates cached token on successful refresh", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "initial_token", "expires_in" => 3600})
      end)

      assert {:ok, "initial_token"} = Teya.Auth.token()

      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "refreshed_token", "expires_in" => 3600})
      end)

      send(auth_pid, :refresh)
      :sys.get_state(auth_pid)

      assert {:ok, "refreshed_token"} = Teya.Auth.token()
    end

    test "schedules a retry when refresh fails", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "service_unavailable"})
      end)

      send(auth_pid, :refresh)
      state = :sys.get_state(auth_pid)

      assert is_reference(state.refresh_timer_ref)
    end
  end
end
