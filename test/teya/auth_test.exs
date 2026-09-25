defmodule Teya.AuthTest do
  use ExUnit.Case, async: false

  alias Teya.TestEnv

  setup do
    auth_pid = Process.whereis(Teya.Auth)
    # Reset cached token to force a fresh fetch on each test
    :sys.replace_state(auth_pid, fn state ->
      if state.refresh_timer_ref, do: Process.cancel_timer(state.refresh_timer_ref)
      %{state | token: nil, expires_at: nil, refresh_timer_ref: nil, retry_count: 0}
    end)

    # A refresh timer left running would fire during a later test, one that
    # allows no token stub to the auth process, and crash it. Some tests here
    # leave one due within seconds, so stop it when each test ends.
    on_exit(fn ->
      if pid = Process.whereis(Teya.Auth) do
        :sys.replace_state(pid, fn state ->
          if state.refresh_timer_ref, do: Process.cancel_timer(state.refresh_timer_ref)
          %{state | refresh_timer_ref: nil}
        end)
      end
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
        assert Plug.Conn.get_req_header(conn, "user-agent") == [Teya.HTTP.user_agent()]
        Req.Test.json(conn, %{"access_token" => "fresh_token", "expires_in" => 3600})
      end)

      assert {:ok, "fresh_token"} = Teya.Auth.token()
    end

    test "sends the token request as a form whatever content-type is configured", %{
      auth_pid: auth_pid
    } do
      TestEnv.add(:auth_req_options, headers: [{"content-type", "application/json"}])

      stub_auth(auth_pid, fn conn ->
        assert Plug.Conn.get_req_header(conn, "content-type") == [
                 "application/x-www-form-urlencoded"
               ]

        Req.Test.json(conn, %{"access_token" => "form_token", "expires_in" => 3600})
      end)

      assert {:ok, "form_token"} = Teya.Auth.token()
    end

    test "keeps a token out of the error when the reply cannot be read", %{
      auth_pid: auth_pid
    } do
      for body <- [
            %{"accessToken" => "secret-token-1"},
            %{"access_token" => %{"value" => "secret-token-1"}}
          ] do
        :sys.replace_state(auth_pid, &%{&1 | token: nil, expires_at: nil})
        stub_auth(auth_pid, fn conn -> Req.Test.json(conn, body) end)

        assert {:error, %Teya.Error{status: 200} = error} = Teya.Auth.token()
        refute inspect(error) =~ "secret-token-1"
        assert Process.alive?(auth_pid)
      end
    end

    test "uses a token whose lifetime is missing or given as text", %{auth_pid: auth_pid} do
      for {expires_in, lifetime} <- [{nil, 300}, {"3600", 3600}, {"soon", 300}] do
        :sys.replace_state(auth_pid, &%{&1 | token: nil, expires_at: nil})

        body =
          if expires_in,
            do: %{"access_token" => "tok", "expires_in" => expires_in},
            else: %{"access_token" => "tok"}

        stub_auth(auth_pid, fn conn -> Req.Test.json(conn, body) end)

        assert {:ok, "tok"} = Teya.Auth.token()

        remaining = :sys.get_state(auth_pid).expires_at - System.monotonic_time(:second)
        assert remaining in (lifetime - 5)..lifetime, "expires_in #{inspect(expires_in)}"
      end
    end

    test "returns an error rather than exiting when the token takes too long", %{
      auth_pid: auth_pid
    } do
      TestEnv.put(:token_timeout_ms, 50)

      stub_auth(auth_pid, fn conn ->
        Process.sleep(300)
        Req.Test.json(conn, %{"access_token" => "slow", "expires_in" => 3600})
      end)

      assert {:error, %Teya.Error{message: "timed out waiting for an access token"}} =
               Teya.Auth.token()
    end

    test "does not fetch for callers that gave up while a failing fetch ran", %{
      auth_pid: auth_pid
    } do
      TestEnv.put(:token_timeout_ms, 100)
      fetches = :counters.new(1, [])

      stub_auth(auth_pid, fn conn ->
        :counters.add(fetches, 1, 1)
        Process.sleep(300)
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      # Five callers queue up behind the first fetch, and all give up on it.
      1..5
      |> Enum.map(fn _i -> Task.async(fn -> Teya.Auth.token() end) end)
      |> Enum.each(&assert({:error, %Teya.Error{}} = Task.await(&1)))

      # Let the auth process work through the requests queued behind it.
      :sys.get_state(auth_pid)
      assert :counters.get(fetches, 1) == 1
    end

    test "refreshes a short-lived token halfway through rather than at once", %{
      auth_pid: auth_pid
    } do
      fetches = :counters.new(1, [])

      stub_auth(auth_pid, fn conn ->
        :counters.add(fetches, 1, 1)
        Req.Test.json(conn, %{"access_token" => "short", "expires_in" => 20})
      end)

      assert {:ok, "short"} = Teya.Auth.token()
      assert {:ok, "short"} = Teya.Auth.token()
      assert :counters.get(fetches, 1) == 1

      state = :sys.get_state(auth_pid)
      assert Process.read_timer(state.refresh_timer_ref) in 5_000..10_000
    end

    # Req.Test ignores timeouts, so this runs the capping but cannot see it
    # take effect: it shows only that configured timeouts do not get in the way.
    test "still fetches when longer timeouts are configured for API calls", %{
      auth_pid: auth_pid
    } do
      TestEnv.add(:auth_req_options, receive_timeout: 60_000, connect_options: [timeout: 60_000])

      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "capped", "expires_in" => 3600})
      end)

      assert {:ok, "capped"} = Teya.Auth.token()
    end

    test "keeps using a cached token that has not expired while the token server is down", %{
      auth_pid: auth_pid
    } do
      :sys.replace_state(auth_pid, fn state ->
        %{state | token: "still-good", expires_at: System.monotonic_time(:second) + 10}
      end)

      stub_auth(auth_pid, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      assert {:ok, "still-good"} = Teya.Auth.token()
    end

    test "fetches a new token for each caller when told not to reuse one", %{
      auth_pid: auth_pid
    } do
      fetches = :counters.new(1, [])

      stub_auth(auth_pid, fn conn ->
        :counters.add(fetches, 1, 1)
        Req.Test.json(conn, %{"access_token" => "once", "expires_in" => 0})
      end)

      assert {:ok, "once"} = Teya.Auth.token()
      assert {:ok, "once"} = Teya.Auth.token()
      assert :counters.get(fetches, 1) == 2

      # Refreshing ahead of time would loop, so there is no refresh timer.
      assert :sys.get_state(auth_pid).refresh_timer_ref == nil
    end

    test "takes a token from any 2xx reply", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"access_token" => "created", "expires_in" => 3600})
      end)

      assert {:ok, "created"} = Teya.Auth.token()
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

      assert {:error, %Teya.Error{code: "invalid_client", status: 401}} = Teya.Auth.token()
    end

    test "returns error on token endpoint transport failure", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} = Teya.Auth.token()
    end

    test "re-fetches once the cached token has expired", %{auth_pid: auth_pid} do
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
    test "waits a minute at most between retries, however many have failed", %{
      auth_pid: auth_pid
    } do
      stub_auth(auth_pid, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      :sys.replace_state(auth_pid, &%{&1 | retry_count: 5_000})
      send(auth_pid, :refresh)
      state = :sys.get_state(auth_pid)

      assert Process.alive?(auth_pid)
      assert state.retry_count == 5_001
      assert Process.read_timer(state.refresh_timer_ref) in 59_000..60_000
    end

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

    test "retry delay grows exponentially with each failure", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "service_unavailable"})
      end)

      :sys.replace_state(auth_pid, fn state -> %{state | retry_count: 0} end)
      send(auth_pid, :refresh)
      :sys.get_state(auth_pid)
      state_after_1 = :sys.get_state(auth_pid)
      assert state_after_1.retry_count == 1

      stub_auth(auth_pid, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "service_unavailable"})
      end)

      send(auth_pid, :refresh)
      :sys.get_state(auth_pid)
      state_after_2 = :sys.get_state(auth_pid)
      assert state_after_2.retry_count == 2
    end

    test "resets retry count after successful refresh", %{auth_pid: auth_pid} do
      :sys.replace_state(auth_pid, fn state -> %{state | retry_count: 5} end)

      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "recovered_token", "expires_in" => 3600})
      end)

      send(auth_pid, :refresh)
      :sys.get_state(auth_pid)

      assert :sys.get_state(auth_pid).retry_count == 0
    end
  end
end
