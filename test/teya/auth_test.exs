defmodule Teya.AuthTest do
  use ExUnit.Case, async: false

  import Teya.APICase, only: [reset_auth: 1]

  alias Teya.TestEnv

  setup do
    auth_pid = Process.whereis(Teya.Auth)
    # Reset cached token to force a fresh fetch on each test
    reset_auth(auth_pid)

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

  # Sends a refresh and waits for the fetch it starts to settle. The fetch
  # runs in a task, so the state is only final once its reply is handled.
  defp refresh(auth_pid) do
    start_refresh(auth_pid)
    await_settled(auth_pid)
  end

  defp await_fetch_started(auth_pid, attempts \\ 200) do
    state = :sys.get_state(auth_pid)

    cond do
      state.fetch != nil -> state
      attempts > 0 -> Process.sleep(10) && await_fetch_started(auth_pid, attempts - 1)
      true -> flunk("no token fetch started")
    end
  end

  # Fires a refresh as its timer would: with the ref of the timer the
  # process holds, which stands in for the real one.
  defp start_refresh(auth_pid) do
    ref = make_ref()
    :sys.replace_state(auth_pid, &%{cancel_refresh(&1) | refresh_timer_ref: ref})
    send(auth_pid, {:timeout, ref, :refresh})
  end

  defp cancel_refresh(state) do
    if state.refresh_timer_ref, do: Process.cancel_timer(state.refresh_timer_ref)
    %{state | refresh_timer_ref: nil}
  end

  defp await_settled(auth_pid, attempts \\ 200) do
    state = :sys.get_state(auth_pid)

    cond do
      state.fetch == nil -> state
      attempts > 0 -> Process.sleep(10) && await_settled(auth_pid, attempts - 1)
      true -> flunk("the token fetch did not settle")
    end
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
        assert conn.request_path == "/oauth/v2/oauth-token"
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

    test "ignores options in :auth_req_options that say what the request is", %{
      auth_pid: auth_pid
    } do
      TestEnv.add(:auth_req_options,
        method: :get,
        url: "https://elsewhere.example/collect",
        body: "grant_type=nothing",
        form: [grant_type: "nothing"],
        json: %{"grant_type" => "nothing"},
        params: [leak: "yes"],
        auth: {:bearer, "config-token"},
        headers: [{"authorization", "Bearer header-token"}]
      )

      stub_auth(auth_pid, fn conn ->
        assert conn.method == "POST"
        refute conn.host == "elsewhere.example"
        assert conn.request_path == "/oauth/v2/oauth-token"
        assert conn.query_string == ""
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body)["grant_type"] == "client_credentials"

        Req.Test.json(conn, %{"access_token" => "own_token", "expires_in" => 3600})
      end)

      assert {:ok, "own_token"} = Teya.Auth.token()
    end

    test "does not follow a redirect from the token endpoint", %{auth_pid: auth_pid} do
      TestEnv.add(:auth_req_options, redirect: true)
      test_pid = self()

      stub_auth(auth_pid, fn conn ->
        send(test_pid, :token_request)

        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/collect")
        |> Plug.Conn.send_resp(307, "")
      end)

      assert {:error, %Teya.Error{reason: {:no_token, _reason}}} = Teya.Auth.token()
      assert_received :token_request
      refute_received :token_request
    end

    test "keeps a token out of the error when the reply cannot be read", %{
      auth_pid: auth_pid
    } do
      for body <- [
            %{"accessToken" => "secret-token-1"},
            %{"access_token" => %{"value" => "secret-token-1"}}
          ] do
        :sys.replace_state(auth_pid, &%{&1 | token: nil, usable_until: nil, failure: nil})
        stub_auth(auth_pid, fn conn -> Req.Test.json(conn, body) end)

        assert {:error, %Teya.Error{status: 200} = error} = Teya.Auth.token()
        refute inspect(error) =~ "secret-token-1"
        assert Process.alive?(auth_pid)
      end
    end

    test "uses a token whose lifetime is missing or given as text", %{auth_pid: auth_pid} do
      for {expires_in, lifetime} <- [{nil, 300}, {"3600", 3600}, {"soon", 300}] do
        :sys.replace_state(auth_pid, &%{&1 | token: nil, usable_until: nil, failure: nil})

        body =
          if expires_in,
            do: %{"access_token" => "tok", "expires_in" => expires_in},
            else: %{"access_token" => "tok"}

        stub_auth(auth_pid, fn conn -> Req.Test.json(conn, body) end)

        assert {:ok, "tok"} = Teya.Auth.token()

        remaining = :sys.get_state(auth_pid).usable_until - System.monotonic_time(:second)
        assert remaining in (lifetime - 10)..(lifetime - 5), "expires_in #{inspect(expires_in)}"
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

      assert {:error,
              %Teya.Error{
                message: "timed out waiting for an access token",
                reason: {:no_token, nil}
              }} =
               Teya.Auth.token()
    end

    test "shares a failed fetch with callers queued behind it", %{
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

    test "shares a failed fetch with the callers right behind it", %{auth_pid: auth_pid} do
      fetches = :counters.new(1, [])

      stub_auth(auth_pid, fn conn ->
        :counters.add(fetches, 1, 1)
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "invalid_client"})
      end)

      for _call <- 1..20 do
        assert {:error, %Teya.Error{code: "invalid_client"}} = Teya.Auth.token()
      end

      assert :counters.get(fetches, 1) == 1
    end

    test "stops handing out a token a few seconds before it expires", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "fresh", "expires_in" => 3600})
      end)

      assert {:ok, "fresh"} = Teya.Auth.token()
      remaining = :sys.get_state(auth_pid).usable_until - System.monotonic_time(:second)
      assert remaining in 3590..3595

      # Three seconds from expiry the old token is no longer handed out.
      :sys.replace_state(auth_pid, fn state ->
        now = System.monotonic_time(:second)
        %{state | token: "old", usable_until: now - 2}
      end)

      assert {:ok, "fresh"} = Teya.Auth.token()
    end

    test "accepts :infinity as the token timeout", %{auth_pid: auth_pid} do
      TestEnv.put(:token_timeout_ms, :infinity)

      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "patient", "expires_in" => 3600})
      end)

      assert {:ok, "patient"} = Teya.Auth.token()
    end

    test "falls back to the default when the token timeout is not a time", %{auth_pid: auth_pid} do
      TestEnv.put(:token_timeout_ms, "soon")

      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "default_wait", "expires_in" => 3600})
      end)

      assert {:ok, "default_wait"} = Teya.Auth.token()
    end

    test "keeps a token that lives longer than a timer can wait", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "long", "expires_in" => 5_000_000})
      end)

      assert {:ok, "long"} = Teya.Auth.token()
      assert Process.alive?(auth_pid)
      assert Process.read_timer(:sys.get_state(auth_pid).refresh_timer_ref) <= 4_294_967_295
    end

    test "keeps using a cached token that has not expired while the token server is down", %{
      auth_pid: auth_pid
    } do
      :sys.replace_state(auth_pid, fn state ->
        now = System.monotonic_time(:second)
        %{state | token: "still-good", usable_until: now + 5}
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

    test "reads a lifetime given as a decimal number", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "decimal", "expires_in" => 60.0})
      end)

      assert {:ok, "decimal"} = Teya.Auth.token()
      remaining = :sys.get_state(auth_pid).usable_until - System.monotonic_time(:second)
      assert remaining in 50..55
    end

    test "fetches when a cached token has no time it may be used until", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "replacement", "expires_in" => 3600})
      end)

      :sys.replace_state(auth_pid, &%{&1 | token: "stale", usable_until: nil})

      assert {:ok, "replacement"} = Teya.Auth.token()
    end

    test "hands out the cached token at once while a slow refresh runs", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Process.sleep(500)
        Req.Test.json(conn, %{"access_token" => "next", "expires_in" => 3600})
      end)

      :sys.replace_state(auth_pid, fn state ->
        now = System.monotonic_time(:second)
        %{state | token: "current", usable_until: now + 15}
      end)

      start_refresh(auth_pid)
      assert %{fetch: %{}} = :sys.get_state(auth_pid)

      assert {:ok, "current"} = Teya.Auth.token()

      # Answered while the refresh was still running, so it did not wait on it.
      assert %{fetch: %{kind: :refresh}} = :sys.get_state(auth_pid)

      # Let the refresh finish inside this test, while its stub is still here,
      # and see that it took the new token.
      assert %{token: "next"} = await_settled(auth_pid)
    end

    test "answers every caller waiting on a fetch with its one token", %{auth_pid: auth_pid} do
      fetches = :counters.new(1, [])

      stub_auth(auth_pid, fn conn ->
        :counters.add(fetches, 1, 1)
        Process.sleep(200)
        Req.Test.json(conn, %{"access_token" => "shared", "expires_in" => 3600})
      end)

      1..10
      |> Enum.map(fn _i -> Task.async(fn -> Teya.Auth.token() end) end)
      |> Enum.each(&assert({:ok, "shared"} = Task.await(&1)))

      assert :counters.get(fetches, 1) == 1
    end

    test "reports a fetch that raised without logging what it raised", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn _conn -> raise "client_secret=hunter2" end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Teya.Error{message: "the token request failed"} = error} =
                   Teya.Auth.token()

          refute inspect(error) =~ "hunter2"
        end)

      refute log =~ "hunter2"
      assert Process.alive?(auth_pid)
    end

    test "reports a fetch that exited", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn _conn -> exit(:boom) end)

      assert {:error, %Teya.Error{message: "the token request failed"}} = Teya.Auth.token()
    end

    test "reports a fetch killed from outside to the callers waiting on it", %{
      auth_pid: auth_pid
    } do
      stub_auth(auth_pid, fn conn ->
        Process.sleep(5_000)
        Req.Test.json(conn, %{"access_token" => "never", "expires_in" => 3600})
      end)

      caller = Task.async(fn -> Teya.Auth.token() end)
      %{fetch: %{pid: pid}} = await_fetch_started(auth_pid)
      Process.exit(pid, :kill)

      assert {:error, %Teya.Error{message: "the token request failed"}} = Task.await(caller)
    end

    test "stops a fetch that runs past its limit, so later callers are not stuck", %{
      auth_pid: auth_pid
    } do
      TestEnv.put(:token_timeout_ms, 100)

      stub_auth(auth_pid, fn conn ->
        Process.sleep(5_000)
        Req.Test.json(conn, %{"access_token" => "never", "expires_in" => 3600})
      end)

      assert {:error, %Teya.Error{}} = Teya.Auth.token()

      assert %{
               fetch: nil,
               failure: {_failed_at, %Teya.Error{message: "the token request took too long"}}
             } = await_settled(auth_pid)
    end

    test "ignores a refresh queued before a caller's fetch stored a new token", %{
      auth_pid: auth_pid
    } do
      fetches = :counters.new(1, [])

      stub_auth(auth_pid, fn conn ->
        :counters.add(fetches, 1, 1)
        Req.Test.json(conn, %{"access_token" => "fresh", "expires_in" => 3600})
      end)

      # A refresh timer is current, and its token has run out.
      timer = make_ref()
      expired_at = System.monotonic_time(:second) - 1

      :sys.replace_state(
        auth_pid,
        &%{&1 | token: "expired", usable_until: expired_at, refresh_timer_ref: timer}
      )

      # A caller's fetch stores a new token, and with it a new refresh timer.
      assert {:ok, "fresh"} = Teya.Auth.token()

      # The old timer's message, already sent before it was cancelled, arrives.
      send(auth_pid, {:timeout, timer, :refresh})

      assert %{fetch: nil} = :sys.get_state(auth_pid)
      assert :counters.get(fetches, 1) == 1
    end

    test "ignores a refresh queued before a failed fetch scheduled its retry", %{
      auth_pid: auth_pid
    } do
      fetches = :counters.new(1, [])

      stub_auth(auth_pid, fn conn ->
        :counters.add(fetches, 1, 1)
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      timer = make_ref()
      expired_at = System.monotonic_time(:second) - 1

      :sys.replace_state(
        auth_pid,
        &%{&1 | token: "expired", usable_until: expired_at, refresh_timer_ref: timer}
      )

      # The caller's fetch fails; with a token cached, a retry is scheduled.
      assert {:error, %Teya.Error{}} = Teya.Auth.token()
      %{refresh_timer_ref: retry_timer} = :sys.get_state(auth_pid)
      assert is_reference(retry_timer)

      send(auth_pid, {:timeout, timer, :refresh})

      # No fetch now; the retry keeps its delay.
      assert %{fetch: nil, refresh_timer_ref: ^retry_timer} = :sys.get_state(auth_pid)
      assert :counters.get(fetches, 1) == 1
    end

    test "keeps only callers still waiting while a fetch stalls", %{auth_pid: auth_pid} do
      TestEnv.put(:token_timeout_ms, 100)

      stub_auth(auth_pid, fn conn ->
        Process.sleep(5_000)
        Req.Test.json(conn, %{"access_token" => "never", "expires_in" => 3600})
      end)

      # Three callers in turn, each giving up before the next arrives.
      for _caller <- 1..3, do: assert({:error, %Teya.Error{}} = Teya.Auth.token())

      # The latest caller has given up too, but no one has cleared it out yet;
      # the two before it were cleared when it arrived.
      assert %{fetch: %{}, waiters: [_only_the_latest]} = :sys.get_state(auth_pid)

      await_settled(auth_pid)
    end

    test "does not fetch for a caller that has already given up", %{auth_pid: auth_pid} do
      gave_up_at = System.monotonic_time(:millisecond) - 1

      # Straight to the process, below token/0, which adds the :no_token reason.
      assert {:error, %Teya.Error{message: "timed out waiting for an access token", reason: nil}} =
               GenServer.call(auth_pid, {:token, gave_up_at})

      assert %{fetch: nil, waiters: []} = :sys.get_state(auth_pid)
    end

    test "ignores a refresh whose timer has been replaced", %{auth_pid: auth_pid} do
      :sys.replace_state(auth_pid, &%{&1 | refresh_timer_ref: make_ref()})
      send(auth_pid, {:timeout, make_ref(), :refresh})

      assert %{fetch: nil} = :sys.get_state(auth_pid)
    end

    test "gives a token too short-lived to cache only to the callers who waited", %{
      auth_pid: auth_pid
    } do
      fetches = :counters.new(1, [])

      stub_auth(auth_pid, fn conn ->
        :counters.add(fetches, 1, 1)
        Req.Test.json(conn, %{"access_token" => "brief", "expires_in" => 3})
      end)

      assert {:ok, "brief"} = Teya.Auth.token()
      assert {:ok, "brief"} = Teya.Auth.token()
      assert :counters.get(fetches, 1) == 2
    end

    test "returns an error when the auth process is not running", %{auth_pid: auth_pid} do
      Process.unregister(Teya.Auth)

      try do
        assert {:error,
                %Teya.Error{
                  message: "the auth process is not available",
                  reason: {:no_token, nil}
                }} =
                 Teya.Auth.token()
      after
        Process.register(auth_pid, Teya.Auth)
      end
    end

    test "ignores a stale fetch reply, and logs a message it does not expect", %{
      auth_pid: auth_pid
    } do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(auth_pid, {make_ref(), {:ok, "stray", 0}})
          send(auth_pid, {:DOWN, make_ref(), :process, self(), :normal})
          send(auth_pid, {:fetch_timeout, make_ref()})
          send(auth_pid, :something_else)
          assert %{token: nil} = :sys.get_state(auth_pid)
        end)

      assert log =~ "unexpected message :something_else"
      refute log =~ "stray"
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

      assert {:error, %Teya.Error{reason: {:no_token, %Req.TransportError{reason: :timeout}}}} =
               Teya.Auth.token()
    end

    test "marks a failure held in any other form as no token", %{auth_pid: auth_pid} do
      :sys.replace_state(auth_pid, fn state ->
        %{
          state
          | failure: {System.monotonic_time(:millisecond), %Req.TransportError{reason: :closed}}
        }
      end)

      assert {:error, %Teya.Error{reason: {:no_token, %Req.TransportError{reason: :closed}}}} =
               Teya.Auth.token()
    end

    test "keeps the status but none of a token reply whose JSON will not decode", %{
      auth_pid: auth_pid
    } do
      garbled = ~s({"access_token":"SECRET-TOKEN", "client_secret":"SECRET-KEY" broken)

      for status <- [200, 401] do
        :sys.replace_state(auth_pid, &%{&1 | failure: nil})

        stub_auth(auth_pid, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, garbled)
        end)

        assert {:error, %Teya.Error{status: ^status} = error} = Teya.Auth.token()
        refute inspect(error) =~ "SECRET"
      end
    end

    test "re-fetches once the cached token has expired", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "fresh_token", "expires_in" => 3600})
      end)

      :sys.replace_state(auth_pid, fn state ->
        %{state | token: "old_token", usable_until: System.monotonic_time(:second) - 1}
      end)

      assert {:ok, "fresh_token"} = Teya.Auth.token()
    end
  end

  describe "proactive refresh" do
    test "cancels a live refresh before scheduling a retry", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      live = :erlang.start_timer(60_000, auth_pid, :refresh)
      expired_at = System.monotonic_time(:second) - 1

      :sys.replace_state(
        auth_pid,
        &%{&1 | token: "expired", usable_until: expired_at, refresh_timer_ref: live}
      )

      # The caller's fetch fails; with a token cached, a retry takes the place
      # of the live timer. Callers are answered before the retry is
      # scheduled, so read the state first, which waits for it.
      assert {:error, %Teya.Error{}} = Teya.Auth.token()
      assert %{refresh_timer_ref: retry} = :sys.get_state(auth_pid)
      assert is_reference(retry) and retry != live
      assert Process.read_timer(live) == false
    end

    test "waits a minute at most between retries, however many have failed", %{
      auth_pid: auth_pid
    } do
      stub_auth(auth_pid, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "down"})
      end)

      :sys.replace_state(auth_pid, &%{&1 | retry_count: 5_000})
      state = refresh(auth_pid)

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

      refresh(auth_pid)

      assert {:ok, "refreshed_token"} = Teya.Auth.token()
    end

    test "schedules a retry when refresh fails", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "service_unavailable"})
      end)

      state = refresh(auth_pid)

      assert is_reference(state.refresh_timer_ref)
    end

    test "retry delay grows exponentially with each failure", %{auth_pid: auth_pid} do
      stub_auth(auth_pid, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "service_unavailable"})
      end)

      :sys.replace_state(auth_pid, fn state -> %{state | retry_count: 0} end)
      state_after_1 = refresh(auth_pid)
      assert state_after_1.retry_count == 1

      stub_auth(auth_pid, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "service_unavailable"})
      end)

      state_after_2 = refresh(auth_pid)
      assert state_after_2.retry_count == 2
    end

    test "resets retry count after successful refresh", %{auth_pid: auth_pid} do
      :sys.replace_state(auth_pid, fn state -> %{state | retry_count: 5} end)

      stub_auth(auth_pid, fn conn ->
        Req.Test.json(conn, %{"access_token" => "recovered_token", "expires_in" => 3600})
      end)

      refresh(auth_pid)

      assert :sys.get_state(auth_pid).retry_count == 0
    end
  end
end
