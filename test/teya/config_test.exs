defmodule Teya.ConfigTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Teya.Config

  describe "from_env/0" do
    test "loads configuration from application env" do
      config = Config.from_env()

      assert config.client_id == "test_client_id"
      assert config.client_secret == "test_client_secret"
      assert config.token_url == "https://identity.teya.test/connect/token"
      assert config.base_url == "https://api.teya.test"
      assert config.scopes == ["checkout/sessions/create", "checkout/sessions/id/get"]
    end

    test "raises ArgumentError when client_id is nil" do
      Application.put_env(:teya, :client_id, nil)

      assert_raise ArgumentError, ~r/:client_id must be a non-empty string/, fn ->
        Config.from_env()
      end
    after
      Application.put_env(:teya, :client_id, "test_client_id")
    end

    test "raises ArgumentError when client_secret is nil" do
      Application.put_env(:teya, :client_secret, nil)

      assert_raise ArgumentError, ~r/:client_secret must be a non-empty string/, fn ->
        Config.from_env()
      end
    after
      Application.put_env(:teya, :client_secret, "test_client_secret")
    end

    test "raises ArgumentError when client_id is blank" do
      Application.put_env(:teya, :client_id, "")

      assert_raise ArgumentError, ~r/:client_id must be a non-empty string/, fn ->
        Config.from_env()
      end
    after
      Application.put_env(:teya, :client_id, "test_client_id")
    end

    test "raises ArgumentError when client_secret is blank" do
      Application.put_env(:teya, :client_secret, "")

      assert_raise ArgumentError, ~r/:client_secret must be a non-empty string/, fn ->
        Config.from_env()
      end
    after
      Application.put_env(:teya, :client_secret, "test_client_secret")
    end

    test "logs a warning when scopes is empty" do
      Application.put_env(:teya, :scopes, [])

      assert capture_log(fn -> Config.from_env() end) =~ "no :scopes configured"
    after
      Application.put_env(:teya, :scopes, ["checkout/sessions/create", "checkout/sessions/id/get"])
    end
  end
end
