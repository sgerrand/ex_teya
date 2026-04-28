defmodule Teya.ReceiptTest do
  use Teya.APICase, async: false

  describe "create/3" do
    test "sends a receipt request and returns 202 accepted" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/transactions/txn-uuid-9012/receipts"

        json_response(conn, 202, %{})
      end)

      assert {:ok, _} = Teya.Receipt.create("txn-uuid-9012")
    end

    test "accepts receipt params" do
      stub_api(fn conn ->
        assert conn.request_path == "/v1/transactions/txn-uuid-9012/receipts"
        json_response(conn, 202, %{"receipt_id" => "rcpt-uuid-5678"})
      end)

      params = %{"email" => "customer@example.com"}
      assert {:ok, response} = Teya.Receipt.create("txn-uuid-9012", params)
      assert response["receipt_id"] == "rcpt-uuid-5678"
    end

    test "returns Teya.Error on bad request" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Invalid email address")
      end)

      assert {:error, %Teya.Error{code: "BAD_REQUEST", status: 400}} =
               Teya.Receipt.create("txn-uuid-9012", %{"email" => "not-an-email"})
    end
  end
end
