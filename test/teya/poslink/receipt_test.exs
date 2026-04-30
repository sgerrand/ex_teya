defmodule Teya.POSLink.ReceiptTest do
  use Teya.APICase, async: false

  alias Teya.Error
  alias Teya.POSLink.Receipt

  describe "create/2" do
    test "creates a receipt request successfully" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/poslink/v1/receipt-requests"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]

        json_response(conn, 201, %{
          "receipt_id" => "receipt-uuid-1",
          "status" => "ENQUEUED"
        })
      end)

      params = %{
        "store_id" => "store-uuid-1",
        "terminal_id" => "term-uuid-1",
        "content" => %{
          "type" => "JSON",
          "data" => %{"merchant" => "Acme Ltd", "total" => "£10.00"}
        }
      }

      assert {:ok, response} = Receipt.create(params)
      assert response["receipt_id"] == "receipt-uuid-1"
      assert response["status"] == "ENQUEUED"
    end

    test "accepts a custom idempotency key" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["receipt-ref-99"]
        json_response(conn, 201, %{"receipt_id" => "receipt-uuid-2", "status" => "ENQUEUED"})
      end)

      params = %{
        "store_id" => "store-uuid-1",
        "terminal_id" => "term-uuid-1",
        "content" => %{"type" => "JSON", "data" => %{}}
      }

      assert {:ok, _} = Receipt.create(params, idempotency_key: "receipt-ref-99")
    end

    test "returns Teya.Error on 400 bad request" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Missing required field: content")
      end)

      assert {:error, %Error{code: "BAD_REQUEST", status: 400}} =
               Receipt.create(%{"store_id" => "store-uuid-1"})
    end

    test "returns Teya.Error on 404 terminal not found" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Terminal not found")
      end)

      assert {:error, %Error{status: 404}} =
               Receipt.create(%{"terminal_id" => "bad-uuid"})
    end

    test "returns Teya.Error on 429 rate limit" do
      stub_api(fn conn ->
        error_response(conn, 429, "TOO_MANY_REQUESTS", "Rate limit exceeded")
      end)

      assert {:error, %Error{status: 429}} =
               Receipt.create(%{})
    end
  end
end
