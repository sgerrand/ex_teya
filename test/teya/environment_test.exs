defmodule Teya.EnvironmentTest do
  # Which API and token URLs the library uses: the :environment's, unless
  # :base_url or :token_url is set.
  use Teya.APICase, async: false

  alias Teya.{Checkout, Config, HTTP, TestEnv}

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

  test "an API call goes to the environment's host" do
    unset_urls()
    TestEnv.put(:environment, :staging)

    stub_api(fn conn ->
      assert conn.host == "api.teya.xyz"
      json_response(conn, 200, %{"ok" => true})
    end)

    assert {:ok, _} = Checkout.get_session("cs-1")
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
