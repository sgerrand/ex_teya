defmodule Teya.EnvironmentTest do
  # Which API and token URLs the library uses: the :environment's, unless
  # :base_url or :token_url is set.
  use Teya.APICase, async: false

  import Teya.POSLink.SubscribeCase, only: [stub_sse: 1]

  alias Teya.{Checkout, Config, HTTP, StartRecord, TestEnv}
  alias Teya.POSLink.{Epos, Payment}

  # The test config sets both URLs. Unset them, so the environment decides.
  defp unset_urls do
    TestEnv.put(:base_url, nil)
    TestEnv.put(:token_url, nil)
  end

  test "uses Teya's production URLs by default" do
    unset_urls()

    assert HTTP.base_url() == "https://api.teya.com"
    assert HTTP.token_url() == "https://id.teya.com/oauth/v2/oauth-token"
  end

  test "uses Teya's staging URLs for environment: :staging" do
    unset_urls()
    TestEnv.put(:environment, :staging)

    assert HTTP.base_url() == "https://api.teya.xyz"
    assert HTTP.token_url() == "https://id.teya.xyz/oauth/v2/oauth-token"

    assert Config.from_env().token_url == "https://id.teya.xyz/oauth/v2/oauth-token"
  end

  test "takes the environment as text too" do
    unset_urls()
    TestEnv.put(:environment, "staging")

    assert HTTP.base_url() == "https://api.teya.xyz"
  end

  test "treats an empty URL as not set" do
    TestEnv.put(:base_url, "")
    TestEnv.put(:token_url, "")

    assert HTTP.base_url() == "https://api.teya.com"
    assert HTTP.token_url() == "https://id.teya.com/oauth/v2/oauth-token"
  end

  describe "a token fetch" do
    # Points the running auth process at the token URL Config.from_env/0 now
    # gives, with no token cached, and puts its state back afterwards.
    setup do
      auth_pid = Process.whereis(Teya.Auth)
      seeded = :sys.get_state(auth_pid)

      on_exit(fn ->
        :sys.replace_state(auth_pid, fn state ->
          if state.refresh_timer_ref, do: Process.cancel_timer(state.refresh_timer_ref)
          seeded
        end)
      end)

      %{auth_pid: auth_pid}
    end

    defp fetch_token(auth_pid) do
      :sys.replace_state(auth_pid, fn state ->
        %{state | config: Config.from_env(), token: nil, expires_at: nil, usable_until: nil}
      end)

      test = self()

      Req.Test.stub(Teya.Auth, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(test, {:token_request, conn, URI.decode_query(body)})
        Req.Test.json(conn, %{"access_token" => "env-token", "expires_in" => 3600})
      end)

      Req.Test.allow(Teya.Auth, self(), auth_pid)

      assert {:ok, "env-token"} = Teya.Auth.token()
      assert_receive {:token_request, conn, form}, 500
      {conn, form}
    end

    for {environment, host} <- [production: "id.teya.com", staging: "id.teya.xyz"] do
      test "goes to the #{environment} token endpoint as a client credentials form", %{
        auth_pid: auth_pid
      } do
        unset_urls()
        TestEnv.put(:environment, unquote(environment))

        {conn, form} = fetch_token(auth_pid)

        assert conn.method == "POST"
        assert conn.host == unquote(host)
        assert conn.request_path == "/oauth/v2/oauth-token"

        assert Plug.Conn.get_req_header(conn, "content-type") == [
                 "application/x-www-form-urlencoded"
               ]

        assert form == %{
                 "grant_type" => "client_credentials",
                 "client_id" => "test_client_id",
                 "client_secret" => "test_client_secret",
                 "scope" => "checkout/sessions/create checkout/sessions/id/get"
               }
      end
    end
  end

  describe "the host a request goes to" do
    # Starts a set of credentials as the application would at boot, under
    # the environment configured now, with a token cached.
    defp start_set(name) do
      TestEnv.put(:credentials, [
        {name, [client_id: "id", client_secret: "secret", scopes: ["s"]]}
      ])

      TestEnv.record_started_sets([name])

      pid = start_supervised!({Teya.Auth, Config.from_env(name)})

      :sys.replace_state(pid, fn state ->
        now = System.monotonic_time(:second)
        %{state | token: "#{name}-token", expires_at: now + 3600, usable_until: now + 3600}
      end)
    end

    defp stub_expecting(host, token) do
      stub_api(fn conn ->
        assert conn.host == host
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{token}"]
        json_response(conn, 200, %{"ok" => true})
      end)
    end

    test "is the host of the environment its credentials started in" do
      unset_urls()
      TestEnv.put(:environment, :staging)
      start_set(:stage)

      # The staging set's token goes to the staging host...
      stub_expecting("api.teya.xyz", "stage-token")
      assert {:ok, _} = Checkout.get_session("cs-1", credentials: :stage)

      # ...and the top-level token, from the test config at boot, to its own.
      stub_expecting("api.teya.test", "test_access_token")
      assert {:ok, _} = Checkout.get_session("cs-1")
    end

    test "does not move when the environment changes while running" do
      start_set(:stage)

      unset_urls()
      TestEnv.put(:environment, :staging)

      stub_expecting("api.teya.test", "stage-token")
      assert {:ok, _} = Checkout.get_session("cs-1", credentials: :stage)
    end

    test "is the stream's host too" do
      unset_urls()
      TestEnv.put(:environment, :staging)
      start_set(:stage)
      # Changed after the set started, so the config now and the set differ.
      TestEnv.put(:environment, :production)

      stub_sse(fn conn ->
        assert conn.host == "api.teya.xyz"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer stage-token"]

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "event: full\ndata: {\"status\":\"NEW\"}\n\n")
      end)

      assert {:ok, %{"status" => "NEW"}} =
               Payment.get("pr-1", credentials: :stage)
    end

    # Registration carries a signed-in user's token, which no set holds, so
    # it goes to the host the application started with, where every set's
    # requests go, whatever the config says now.
    test "for ePOS registration, is the one the application started with" do
      unset_urls()
      TestEnv.put(:environment, :staging)
      stub_expecting("api.teya.test", "user-jwt")

      assert {:ok, _} = Epos.register(%{}, user_token: "user-jwt")
    end
  end

  describe "starting the application" do
    # Takes the :client_id away for the test, so starting builds no auth
    # process for the top-level credentials.
    defp without_client_id do
      {:ok, client_id} = Application.fetch_env(:teya, :client_id)
      Application.delete_env(:teya, :client_id)
      on_exit(fn -> Application.put_env(:teya, :client_id, client_id) end)
    end

    test "a restart records its settings, before its auth processes start" do
      # Registered first, so it runs last: after TestEnv has put the config
      # back, the application restarts as the other tests expect it.
      on_exit(fn ->
        Application.stop(:teya)
        {:ok, _apps} = Application.ensure_all_started(:teya)
      end)

      TestEnv.put(:base_url, "https://restarted.example")

      :ok = Application.stop(:teya)
      {:ok, _apps} = Application.ensure_all_started(:teya)

      # Registration and the restarted auth process got the same host.
      assert HTTP.started_base_url() == "https://restarted.example"
      assert :sys.get_state(Teya.Auth).config.base_url == "https://restarted.example"
    end

    test "a start that fails leaves no settings recorded" do
      # Registered first, so it runs last, once the name is free again.
      on_exit(fn -> {:ok, _apps} = Application.ensure_all_started(:teya) end)

      :ok = Application.stop(:teya)

      # A child's name already taken, so the supervisor cannot start.
      squatter = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(squatter, Teya.TaskSupervisor)

      # Waits until it is gone: Process.exit/2 only sends the signal, and the
      # restart above would fail on the name if it were still taken.
      on_exit(fn ->
        ref = Process.monitor(squatter)
        Process.exit(squatter, :kill)
        assert_receive {:DOWN, ^ref, :process, ^squatter, _reason}, 5_000
      end)

      TestEnv.put(:credentials, online: [client_id: "a", client_secret: "b", scopes: ["s"]])
      assert {:error, _reason} = Application.ensure_all_started(:teya)

      assert StartRecord.base_url() == nil
      assert StartRecord.sets() == []
    end

    test "keeps the host it started with when a second start finds it running" do
      TestEnv.put(:base_url, "https://proxy.example")
      TestEnv.put(:credentials, online: [client_id: "a", client_secret: "b", scopes: ["s"]])
      sets = StartRecord.sets()

      assert {:error, {:already_started, _pid}} = Teya.Application.start(:normal, [])

      assert HTTP.started_base_url() == "https://api.teya.test"
      assert StartRecord.sets() == sets
    end

    test "a start that resolves no host erases the one an earlier run left" do
      TestEnv.keep_start_record()
      unset_urls()
      TestEnv.put(:environment, :sandbox)

      # As a later start in the same VM, with an environment it did not know.
      StartRecord.record([], nil)

      # Registration then reports the environment instead of using the old host.
      assert_raise ArgumentError, ~r/:environment must be/, fn ->
        Epos.register(%{}, user_token: "user-jwt")
      end
    end

    test "stopping clears what the run resolved" do
      on_exit(fn -> {:ok, _apps} = Application.ensure_all_started(:teya) end)

      :ok = Application.stop(:teya)

      assert StartRecord.base_url() == nil
      assert StartRecord.sets() == []
    end

    test "is not stopped by an environment it does not know, with no credentials" do
      # Registered first, so it runs last, once the config is back.
      on_exit(fn ->
        Application.stop(:teya)
        {:ok, _apps} = Application.ensure_all_started(:teya)
      end)

      without_client_id()
      unset_urls()
      TestEnv.put(:environment, :sandbox)

      # An app that makes no requests, such as one that only checks
      # webhooks, starts; the environment is reported where it is used.
      :ok = Application.stop(:teya)
      assert {:ok, _apps} = Application.ensure_all_started(:teya)
      assert Process.whereis(Teya.Supervisor)

      # With no host recorded, a request with no set reports it.
      assert_raise ArgumentError, ~r/:environment must be/, fn -> HTTP.started_base_url() end
    end
  end

  test ":base_url and :token_url win over the environment" do
    TestEnv.put(:environment, :staging)
    TestEnv.put(:base_url, "https://proxy.example")
    TestEnv.put(:token_url, "https://proxy.example/token")

    assert HTTP.base_url() == "https://proxy.example"
    assert HTTP.token_url() == "https://proxy.example/token"
  end

  test "raises for an environment it does not know, even with both URLs set" do
    TestEnv.put(:environment, :sandbox)

    assert_raise ArgumentError, ~r/:environment must be :production or :staging/, fn ->
      Config.from_env()
    end
  end

  test "raises for an environment it does not know" do
    unset_urls()
    TestEnv.put(:environment, :sandbox)

    assert_raise ArgumentError,
                 ~r/:environment must be :production or :staging, got: :sandbox/,
                 fn ->
                   HTTP.base_url()
                 end
  end
end
