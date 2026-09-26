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

    config = Config.from_env()
    assert config.base_url == "https://api.teya.xyz"
    assert config.token_url == "https://id.teya.xyz/oauth/v2/oauth-token"
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
