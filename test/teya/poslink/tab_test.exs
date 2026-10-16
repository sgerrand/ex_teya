defmodule Teya.POSLink.TabTest do
  use Teya.APICase, async: false

  alias Teya.Error
  alias Teya.POSLink.Tab

  @tab %{
    "tab_id" => "tab-uuid-1",
    "store_id" => "store-uuid-1",
    "tab_name" => "Table 4",
    "status" => "OPEN",
    "total_amount" => %{"amount" => 0, "currency" => "GBP"},
    "total_paid" => 0,
    "remaining" => 0,
    "merchant_reference" => "table-4-1830",
    "payment_requests" => []
  }

  defp read_json(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  describe "create/2" do
    @params %{
      "store_id" => "store-uuid-1",
      "tab_name" => "Table 4",
      "merchant_reference" => "table-4-1830",
      "currency_code" => "GBP"
    }

    test "creates a tab, with an idempotency key" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/poslink/v1/tabs"
        assert [_key] = Plug.Conn.get_req_header(conn, "idempotency-key")
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]

        {body, conn} = read_json(conn)
        assert body == @params

        json_response(conn, 201, @tab)
      end)

      assert {:ok, %{"tab_id" => "tab-uuid-1", "status" => "OPEN"}} = Tab.create(@params)
    end

    test "sends the idempotency key it is given" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["table-4-1830"]
        json_response(conn, 201, @tab)
      end)

      assert {:ok, _tab} = Tab.create(@params, idempotency_key: "table-4-1830")
    end

    test "returns Teya.Error when the store already has a tab with the reference" do
      stub_api(fn conn ->
        error_response(conn, 409, "CONFLICT", "Tab with merchant_reference already exists")
      end)

      assert {:error, %Error{status: 409, code: "CONFLICT"}} = Tab.create(@params)
    end
  end

  describe "list/2" do
    test "lists a store's tabs" do
      stub_api(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/poslink/v1/tabs"
        assert conn.query_string == "store_id=store-uuid-1"
        json_response(conn, 200, %{"tabs" => [@tab], "paging" => %{}})
      end)

      assert {:ok, %{"tabs" => [%{"tab_id" => "tab-uuid-1"}]}} = Tab.list("store-uuid-1")
    end

    test "sends each of several statuses as the key repeated" do
      stub_api(fn conn ->
        assert conn.query_string ==
                 "store_id=store-uuid-1&status=COMPLETED&status=CLOSED&limit=100"

        json_response(conn, 200, %{"tabs" => [], "paging" => %{}})
      end)

      assert {:ok, %{"tabs" => []}} =
               Tab.list("store-uuid-1", params: [status: ["COMPLETED", "CLOSED"], limit: 100])
    end

    test "takes its params as a map too" do
      stub_api(fn conn ->
        assert URI.decode_query(conn.query_string) == %{
                 "store_id" => "store-uuid-1",
                 "merchant_reference" => "table-4-1830"
               }

        json_response(conn, 200, %{"tabs" => [@tab], "paging" => %{}})
      end)

      assert {:ok, _} =
               Tab.list("store-uuid-1", params: %{merchant_reference: "table-4-1830"})
    end

    test "takes params: nil as no params" do
      stub_api(fn conn ->
        assert conn.query_string == "store_id=store-uuid-1"
        json_response(conn, 200, %{"tabs" => [], "paging" => %{}})
      end)

      assert {:ok, %{"tabs" => []}} = Tab.list("store-uuid-1", params: nil)
    end

    test "raises for a missing store id, before any request" do
      stub_api(fn _conn -> flunk("no request should be sent") end)

      for store_id <- [nil, ""] do
        assert_raise ArgumentError, ~r/needs a store id/, fn -> Tab.list(store_id) end
      end
    end

    test "raises for a store_id in :params, before any request" do
      stub_api(fn _conn -> flunk("no request should be sent") end)

      for params <- [[store_id: "store-uuid-2"], %{"store_id" => "store-uuid-2"}] do
        assert_raise ArgumentError, ~r/store as its first argument/, fn ->
          Tab.list("store-uuid-1", params: params)
        end
      end
    end

    test "raises for an empty list, before any request" do
      stub_api(fn _conn -> flunk("no request should be sent") end)

      assert_raise ArgumentError, ~r/:status in :params is an empty list/, fn ->
        Tab.list("store-uuid-1", params: [status: []])
      end
    end
  end

  describe "get/2" do
    test "fetches a tab" do
      stub_api(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/poslink/v1/tabs/tab-uuid-1"
        json_response(conn, 200, @tab)
      end)

      assert {:ok, %{"tab_id" => "tab-uuid-1"}} = Tab.get("tab-uuid-1")
    end

    test "returns Teya.Error for a tab that does not exist" do
      stub_api(fn conn -> error_response(conn, 404, "TAB_NOT_FOUND", "tab not found") end)

      assert {:error, %Error{status: 404, code: "TAB_NOT_FOUND"}} = Tab.get("tab-uuid-9")
    end
  end

  describe "update/3" do
    test "sends only the fields given, with no idempotency key" do
      params = %{"total_amount" => %{"amount" => 4250, "currency" => "GBP"}}

      stub_api(fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/poslink/v1/tabs/tab-uuid-1"
        # Its spec documents no Idempotency-Key, so none is sent.
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []

        {body, conn} = read_json(conn)
        assert body == params

        json_response(conn, 200, Map.merge(@tab, params))
      end)

      assert {:ok, %{"total_amount" => %{"amount" => 4250}}} = Tab.update("tab-uuid-1", params)
    end
  end

  describe "close/2" do
    test "closes a tab" do
      stub_api(fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/poslink/v1/tabs/tab-uuid-1"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []

        json_response(conn, 200, %{
          "tab_id" => "tab-uuid-1",
          "status" => "CLOSED",
          "closed_at" => "2026-10-15T18:30:00Z"
        })
      end)

      assert {:ok, %{"status" => "CLOSED"}} = Tab.close("tab-uuid-1")
    end

    test "returns Teya.Error for a tab already closed" do
      stub_api(fn conn -> error_response(conn, 409, "TAB_ALREADY_CLOSED", "tab is closed") end)

      assert {:error, %Error{status: 409}} = Tab.close("tab-uuid-1")
    end
  end

  describe "send_bill/3" do
    test "sends the bill, with no idempotency key" do
      params = %{
        "terminal_id" => "term-uuid-1",
        "total_amount" => %{"amount" => 4250, "currency" => "GBP"},
        "tab_item_data" => [%{"name" => "Fish pie", "quantity" => 2, "amount" => 2800}]
      }

      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/poslink/v1/tabs/tab-uuid-1/bill"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []

        {body, conn} = read_json(conn)
        assert body == params

        json_response(conn, 202, %{
          "tab_id" => "tab-uuid-1",
          "status" => "OPEN",
          "showing_bill_terminal_id" => "term-uuid-1"
        })
      end)

      assert {:ok, %{"showing_bill_terminal_id" => "term-uuid-1"}} =
               Tab.send_bill("tab-uuid-1", params)
    end
  end

  describe "report_error/3" do
    test "reports an error to the terminal, with no idempotency key" do
      params = %{
        "terminal_id" => "term-uuid-1",
        "error_code" => "BILL_ALREADY_SETTLED",
        "message" => "This bill has been paid at the till."
      }

      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/poslink/v1/tabs/tab-uuid-1/errors"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []

        {body, conn} = read_json(conn)
        assert body == params

        json_response(conn, 202, %{"tab_id" => "tab-uuid-1", "status" => "OPEN"})
      end)

      assert {:ok, %{"status" => "OPEN"}} = Tab.report_error("tab-uuid-1", params)
    end
  end

  test "a write with no documented key raises when given one" do
    calls = [
      fn -> Tab.update("tab-uuid-1", %{}, idempotency_key: "k") end,
      fn -> Tab.close("tab-uuid-1", idempotency_key: "k") end,
      fn -> Tab.send_bill("tab-uuid-1", %{}, idempotency_key: "k") end,
      fn -> Tab.report_error("tab-uuid-1", %{}, idempotency_key: "k") end
    ]

    for call <- calls do
      assert_raise ArgumentError, ~r/takes no :idempotency_key/, call
    end
  end
end
