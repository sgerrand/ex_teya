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
end
