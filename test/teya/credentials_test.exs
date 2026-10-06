defmodule Teya.CredentialsTest do
  # Named sets of credentials: which set each call uses, that each set has an
  # auth process and token of its own, and that each asks only for its own
  # scopes.
  use Teya.APICase, async: false

  import Teya.POSLink.SubscribeCase, only: [stub_sse: 1]

  alias Teya.{Auth, Checkout, Config, StartRecord, TestEnv}
  alias Teya.POSLink.{Payment, Receipt, Store}

  # Configures the named sets and starts an auth process for each, holding
  # a token named after the set, as the application would at boot.
  defp start_sets(names) do
    TestEnv.put(
      :credentials,
      for(
        name <- names,
        do: {name, [client_id: "id-#{name}", client_secret: "secret", scopes: ["s"]]}
      )
    )

    started(names)

    for name <- names do
      start_supervised!({Auth, Config.from_env(name)})
      seed(name, "#{name}-token")
    end
  end

  # Records the sets as started, as the application does at boot, and puts
  # back what was there when the test ends.
  defp started(names) do
    {sets, base_url} = {StartRecord.sets(), StartRecord.base_url()}
    StartRecord.record(names, base_url)
    on_exit(fn -> StartRecord.record(sets, base_url) end)
  end

  defp seed(name, token) do
    :sys.replace_state(server(name), fn state ->
      now = System.monotonic_time(:second)
      %{state | token: token, expires_at: now + 3600, usable_until: now + 3600}
    end)
  end

  defp server(name), do: Module.concat(Auth, name)

  # Fires a background refresh as its timer would, and waits for the fetch
  # it starts to settle.
  defp refresh(pid) do
    tag = make_ref()
    :sys.replace_state(pid, &%{&1 | refresh_tag: tag, failed_at: nil, failure: nil})
    send(pid, {:refresh, tag})
    await_settled(pid, 200)
  end

  # :sys.get_state/1 is answered after the refresh message, so the first
  # look already sees the fetch it started.
  defp await_settled(pid, attempts) do
    cond do
      :sys.get_state(pid).fetch == nil -> :ok
      attempts > 0 -> Process.sleep(10) && await_settled(pid, attempts - 1)
      true -> flunk("the refresh did not settle")
    end
  end

  defp stub_expecting_token(token) do
    stub_api(fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{token}"]
      json_response(conn, 200, %{"ok" => true})
    end)
  end

  describe "which credentials a call uses" do
    test "with no named sets, every call uses the top-level credentials" do
      stub_expecting_token("test_access_token")

      assert {:ok, _} = Checkout.get_session("cs-1")
      assert {:ok, _} = Store.list()
    end

    test "a POSLink call uses the :poslink set; any other the top-level ones" do
      start_sets([:poslink])

      stub_expecting_token("poslink-token")
      assert {:ok, _} = Store.list()

      stub_expecting_token("test_access_token")
      assert {:ok, _} = Checkout.get_session("cs-1")
    end

    test "any other call uses the :online set when there is one" do
      start_sets([:online])

      stub_expecting_token("online-token")
      assert {:ok, _} = Checkout.get_session("cs-1")

      stub_expecting_token("test_access_token")
      assert {:ok, _} = Store.list()
    end

    test ":credentials picks the top-level credentials as :default" do
      start_sets([:online, :poslink])

      stub_expecting_token("test_access_token")
      assert {:ok, _} = Checkout.get_session("cs-1", credentials: :default)
      assert {:ok, _} = Store.list(credentials: :default)
    end

    test "a set configured but not started is not used" do
      TestEnv.put(:credentials, poslink: [client_id: "a", client_secret: "b", scopes: ["s"]])

      stub_expecting_token("test_access_token")
      assert {:ok, _} = Store.list()
    end

    test ":credentials picks another set" do
      start_sets([:poslink, :store_b])

      stub_expecting_token("store_b-token")
      assert {:ok, _} = Store.list(credentials: :store_b)
    end

    test "a name that is not configured raises before any request" do
      start_sets([:poslink])
      stub_api(fn _conn -> flunk("no request should be sent") end)

      calls = [
        fn -> Store.list(credentials: :nope) end,
        fn -> Checkout.get_session("cs-1", credentials: nil) end,
        fn -> Payment.get("pr-1", credentials: :nope) end,
        fn -> Payment.subscribe("pr-1", self(), credentials: :nope) end,
        fn -> Receipt.subscribe_status("r-1", self(), credentials: :nope) end
      ]

      for call <- calls do
        assert_raise ArgumentError, ~r/no credentials named/, call
      end
    end
  end

  describe "POSLink streams" do
    defp stub_stream_expecting_token(token) do
      stub_sse(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{token}"]

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "event: full\ndata: {\"status\":\"NEW\"}\n\n")
      end)
    end

    test "use the :poslink set, or the one named" do
      start_sets([:poslink, :store_b])

      stub_stream_expecting_token("poslink-token")
      assert {:ok, %{"status" => "NEW"}} = Payment.get("pr-1")

      stub_stream_expecting_token("store_b-token")
      assert {:ok, %{"status" => "NEW"}} = Payment.get("pr-1", credentials: :store_b)

      {:ok, %Task{ref: ref}} = Payment.subscribe("pr-2", self(), credentials: :store_b)
      assert_receive {:poslink_payment, ^ref, "pr-2", "full", _data}, 500

      {:ok, %Task{ref: ref}} = Receipt.subscribe_status("r-1", self(), credentials: :store_b)
      assert_receive {:poslink_receipt, ^ref, "r-1", "full", _data}, 500
    end

    test "take options in place of a pid, for the calling process" do
      start_sets([:poslink, :store_b])
      stub_stream_expecting_token("store_b-token")

      {:ok, %Task{ref: ref}} = Payment.subscribe("pr-3", credentials: :store_b)
      assert_receive {:poslink_payment, ^ref, "pr-3", "full", _data}, 500

      {:ok, %Task{ref: ref}} = Receipt.subscribe_status("r-2", credentials: :store_b)
      assert_receive {:poslink_receipt, ^ref, "r-2", "full", _data}, 500
    end
  end

  describe "each set" do
    test "asks the token endpoint only for its own scopes" do
      TestEnv.put(:credentials,
        poslink: [
          client_id: "epos-client",
          client_secret: "epos-secret",
          scopes: ["payment_requests", "stores/id/terminals"]
        ]
      )

      started([:poslink])
      pid = start_supervised!({Auth, Config.from_env(:poslink)})
      test = self()

      Req.Test.stub(Teya.Auth, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:token_request, URI.decode_query(body)})
        Req.Test.json(conn, %{"access_token" => "fresh-poslink-token", "expires_in" => 3600})
      end)

      Req.Test.allow(Teya.Auth, self(), pid)

      stub_expecting_token("fresh-poslink-token")

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn -> assert {:ok, _} = Store.list() end)

      # Its log lines say which set they are about.
      assert log =~ "Teya.Auth :poslink: token fetched"

      assert_receive {:token_request, form}
      assert form["client_id"] == "epos-client"
      assert form["scope"] == "payment_requests stores/id/terminals"
    end

    test "names itself in its refresh logs, whether the refresh works or fails" do
      started([:store_b])
      TestEnv.put(:credentials, store_b: [client_id: "b", client_secret: "secret", scopes: ["s"]])
      pid = start_supervised!({Auth, Config.from_env(:store_b)})

      for {status, expected} <- [
            {200, "Teya.Auth :store_b: token refreshed"},
            {503, "Teya.Auth :store_b: token refresh failed"}
          ] do
        Req.Test.stub(Teya.Auth, fn conn ->
          conn
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(%{"access_token" => "refreshed-token", "expires_in" => 3600})
        end)

        Req.Test.allow(Teya.Auth, self(), pid)

        log = ExUnit.CaptureLog.capture_log([level: :info], fn -> refresh(pid) end)
        assert log =~ expected
      end
    end

    test "is asked again for its token on a retry" do
      start_sets([:poslink])
      TestEnv.put(:retry_idempotent_posts, true)

      req_options = Application.get_env(:teya, :req_options) |> Keyword.delete(:retry)

      TestEnv.put(
        :req_options,
        req_options ++ [retry_delay: fn _ -> 0 end, retry_log_level: false]
      )

      test = self()
      attempts = :counters.new(1, [])

      stub_api(fn conn ->
        :counters.add(attempts, 1, 1)
        send(test, {:attempt, Plug.Conn.get_req_header(conn, "authorization")})

        if :counters.get(attempts, 1) == 1 do
          seed(:poslink, "rotated-token")
          Plug.Conn.send_resp(conn, 503, "")
        else
          json_response(conn, 200, %{"ok" => true})
        end
      end)

      assert {:ok, _} = Payment.create(%{})
      assert_received {:attempt, ["Bearer poslink-token"]}
      assert_received {:attempt, ["Bearer rotated-token"]}
    end
  end

  describe "the :credentials config" do
    test "stops a mistake at boot with a message that names it, not its secret" do
      set = [client_id: "a", client_secret: "SECRET", scopes: ["s"]]

      cases = [
        {%{online: set}, ~r/keyword list of named sets/},
        {[{"store_1", set}], ~r/named with atoms/},
        {[default: set], ~r/:default names the top-level credentials/},
        {[{nil, set}], ~r/nil names the top-level credentials/},
        {[online: set, online: set], ~r/appears twice/},
        {[online: %{client_id: "a"}], ~r/named with atoms/},
        {[online: [{"client_id", "a"}]], ~r/:online credentials must be a keyword list/}
      ]

      for {credentials, message} <- cases do
        TestEnv.put(:credentials, credentials)
        error = assert_raise ArgumentError, message, &Config.sets/0
        refute Exception.message(error) =~ "SECRET"
      end
    end
  end

  describe "the application" do
    test "starts an auth process for the top-level credentials and each named set" do
      TestEnv.put(:credentials,
        online: [client_id: "a", client_secret: "b", scopes: ["s"]],
        poslink: [client_id: "c", client_secret: "d", scopes: ["s"]]
      )

      ids = for child <- Teya.Application.auth_children(), do: Supervisor.child_spec(child, []).id
      assert ids == [{Auth, nil}, {Auth, :online}, {Auth, :poslink}]
    end

    test "gives every set the same URLs, read once" do
      TestEnv.put(:credentials,
        online: [client_id: "a", client_secret: "b", scopes: ["s"]],
        poslink: [client_id: "c", client_secret: "d", scopes: ["s"]]
      )

      urls = %{base_url: "https://api.example", token_url: "https://id.example/token"}

      for {Auth, config} <- Teya.Application.auth_children(urls) do
        assert {config.base_url, config.token_url} == {urls.base_url, urls.token_url}
      end
    end

    test "restarts one set's auth process alone when it fails" do
      start_sets([:set_a, :set_b, :set_c, :set_d])

      before = for name <- [:set_a, :set_b, :set_c, :set_d], do: Process.whereis(server(name))
      [killed | others] = before
      top_auth = Process.whereis(Teya.Auth)

      Process.exit(killed, :kill)
      await_restarted(:set_a, killed, 200)

      assert Process.whereis(Teya.Auth) == top_auth
      assert for(name <- [:set_b, :set_c, :set_d], do: Process.whereis(server(name))) == others
    end
  end

  defp await_restarted(name, old, attempts) do
    case Process.whereis(server(name)) do
      pid when is_pid(pid) and pid != old ->
        pid

      _other when attempts > 0 ->
        Process.sleep(10)
        await_restarted(name, old, attempts - 1)

      _other ->
        flunk("#{inspect(name)} was not restarted")
    end
  end
end
