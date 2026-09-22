defmodule Teya.POSLink.RefundTest do
  use Teya.APICase, async: false

  alias Teya.Error
  alias Teya.POSLink.Refund

  describe "create/2" do
    test "creates a refund successfully" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/poslink/v2/refunds"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "transaction_id" => "gateway-payment-id-1",
                 "amount" => 1500
               }

        json_response(conn, 201, %{
          "transaction_id" => "refund-txn-1",
          "transaction_type" => "REFUND",
          "status" => "SUCCESS"
        })
      end)

      params = %{"transaction_id" => "gateway-payment-id-1", "amount" => 1500}

      assert {:ok, response} = Refund.create(params)
      assert response["status"] == "SUCCESS"
      assert response["transaction_id"] == "refund-txn-1"
    end

    test "returns pending on 202" do
      stub_api(fn conn ->
        json_response(conn, 202, %{"transaction_id" => "refund-txn-2", "status" => "PENDING"})
      end)

      params = %{"transaction_id" => "gateway-payment-id-1", "amount" => 1500}
      assert {:ok, response} = Refund.create(params)
      assert response["status"] == "PENDING"
    end

    test "accepts a custom idempotency key" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["my-refund-ref"]
        json_response(conn, 201, %{"transaction_id" => "refund-txn-3", "status" => "SUCCESS"})
      end)

      params = %{"transaction_id" => "gateway-payment-id-1", "amount" => 1500}
      assert {:ok, _} = Refund.create(params, idempotency_key: "my-refund-ref")
    end

    test "returns Teya.Error on 404 when payment not found" do
      stub_api(fn conn ->
        error_response(conn, 404, "TRANSACTION_NOT_FOUND", "Transaction not found")
      end)

      assert {:error, %Error{code: "TRANSACTION_NOT_FOUND", status: 404}} =
               Refund.create(%{"transaction_id" => "bad-id", "amount" => 1500})
    end

    test "returns Teya.Error on 409 for duplicate refund" do
      stub_api(fn conn ->
        error_response(conn, 409, "CONFLICT", "Refund already processed")
      end)

      assert {:error, %Error{code: "CONFLICT", status: 409}} =
               Refund.create(%{"transaction_id" => "gateway-payment-id-1", "amount" => 1500})
    end
  end
end
