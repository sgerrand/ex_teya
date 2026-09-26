defmodule Teya.POSLink.StoreTest do
  use Teya.APICase, async: false

  alias Teya.Error
  alias Teya.POSLink.Store

  describe "list/1" do
    test "returns list of stores on success" do
      stub_api(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/poslink/v1/stores"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]

        json_response(conn, 200, %{
          "stores" => [
            %{"store_id" => "store-uuid-1", "name" => "Main Street"},
            %{"store_id" => "store-uuid-2", "name" => "High Street"}
          ]
        })
      end)

      assert {:ok, response} = Store.list()
      assert length(response["stores"]) == 2
      assert hd(response["stores"])["store_id"] == "store-uuid-1"
    end

    test "returns Teya.Error on 401 unauthorized" do
      stub_api(fn conn ->
        error_response(conn, 401, "UNAUTHORISED", "Invalid token")
      end)

      assert {:error, %Error{code: "UNAUTHORISED", status: 401}} =
               Store.list()
    end

    test "returns Teya.Error on 429 rate limit" do
      stub_api(fn conn ->
        error_response(conn, 429, "TOO_MANY_REQUESTS", "Rate limit exceeded")
      end)

      assert {:error, %Error{status: 429}} = Store.list()
    end
  end

  describe "list_terminals/2" do
    test "returns terminals for the given store" do
      store_id = "store-uuid-1"

      stub_api(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/poslink/v1/stores/#{store_id}/terminals"

        json_response(conn, 200, %{
          "terminals" => [
            %{"terminal_id" => "term-uuid-1", "serial_number" => "SN-001"},
            %{"terminal_id" => "term-uuid-2", "serial_number" => "SN-002"}
          ]
        })
      end)

      assert {:ok, response} = Store.list_terminals(store_id)
      assert length(response["terminals"]) == 2
      assert hd(response["terminals"])["terminal_id"] == "term-uuid-1"
    end

    test "returns Teya.Error on 404 for unknown store" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Store not found")
      end)

      assert {:error, %Error{status: 404}} =
               Store.list_terminals("nonexistent-store")
    end
  end

  describe "terminal_configs/3" do
    test "returns the configuration for a terminal in a store" do
      stub_api(fn conn ->
        assert conn.method == "GET"

        assert conn.request_path ==
                 "/poslink/v1/stores/store-uuid-1/terminals/term-1/configs"

        json_response(conn, 200, %{
          "configs" => [%{"config_key" => "PAT_ENABLED", "value" => "true"}]
        })
      end)

      assert {:ok, %{"configs" => [%{"config_key" => "PAT_ENABLED"}]}} =
               Store.terminal_configs("store-uuid-1", "term-1")
    end
  end

  describe "put_config/4" do
    test "sets a configuration value for the store" do
      stub_api(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/poslink/v1/stores/store-uuid-1/configs/PAT_ENABLED"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"value" => "true"}

        json_response(conn, 200, %{"config_key" => "PAT_ENABLED", "value" => "true"})
      end)

      assert {:ok, %{"value" => "true"}} = Store.put_config("store-uuid-1", "PAT_ENABLED", "true")
    end

    test "sends a boolean or a number as the string the API takes" do
      stub_api(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        json_response(conn, 200, Jason.decode!(body))
      end)

      assert {:ok, %{"value" => "true"}} = Store.put_config("store-uuid-1", "PAT_ENABLED", true)
      assert {:ok, %{"value" => "30"}} = Store.put_config("store-uuid-1", "TIMEOUT", 30)
    end

    test "does not take a float, whose text the API may not accept" do
      # The compiler already rejects a float written into the call, so this
      # one comes from a runtime value, to check the guard itself.
      value = Enum.random([30.0])

      assert_raise FunctionClauseError, fn ->
        Store.put_config("store-uuid-1", "TIMEOUT", value)
      end
    end

    test "raises for a missing store id rather than calling another route" do
      assert_raise ArgumentError, ~r/cannot be empty/, fn ->
        Store.put_config(nil, "PAT_ENABLED", "true")
      end
    end

    test "raises for a dot segment, which could reach another route" do
      for id <- [".", ".."] do
        assert_raise ArgumentError, ~r/cannot be empty, "\." or "\.\."/, fn ->
          Store.put_config(id, "PAT_ENABLED", "true")
        end
      end
    end

    test "encodes a key so it cannot change which endpoint is called" do
      stub_api(fn conn ->
        assert conn.request_path == "/poslink/v1/stores/store-uuid-1/configs/A%2FB%3Fx"
        json_response(conn, 200, %{"config_key" => "A/B?x", "value" => "on"})
      end)

      assert {:ok, _} = Store.put_config("store-uuid-1", "A/B?x", "on")
    end

    test "returns Teya.Error for a value the key does not accept" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "PAT_ENABLED accepts true or false")
      end)

      assert {:error, %Error{code: "BAD_REQUEST", status: 400}} =
               Store.put_config("store-uuid-1", "PAT_ENABLED", "maybe")
    end
  end
end
