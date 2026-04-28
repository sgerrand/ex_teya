defmodule Teya.CaptureTest do
  use Teya.APICase, async: false

  describe "create/3" do
    test "captures a pre-authorised transaction" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/transactions/txn-uuid-9012/capture"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []

        json_response(conn, 201, %{"status" => "SUCCESS", "transaction_id" => "txn-uuid-9012"})
      end)

      assert {:ok, response} = Teya.Capture.create("txn-uuid-9012")
      assert response["status"] == "SUCCESS"
    end

    test "returns pending on 202" do
      stub_api(fn conn ->
        json_response(conn, 202, %{"status" => "PENDING", "transaction_id" => "txn-uuid-9012"})
      end)

      assert {:ok, response} = Teya.Capture.create("txn-uuid-9012")
      assert response["status"] == "PENDING"
    end

    test "returns Teya.Error on 404" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Transaction not found")
      end)

      assert {:error, %Teya.Error{status: 404}} = Teya.Capture.create("nonexistent-txn")
    end

    test "returns Teya.Error on 409 duplicate capture" do
      stub_api(fn conn ->
        error_response(conn, 409, "CONFLICT", "Transaction already captured")
      end)

      assert {:error, %Teya.Error{status: 409}} = Teya.Capture.create("txn-uuid-9012")
    end
  end
end
