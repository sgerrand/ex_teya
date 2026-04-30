defmodule Teya.POSLink.RefundTest do
  use Teya.APICase, async: false

  alias Teya.Error
  alias Teya.POSLink.Refund

  describe "create/2" do
    test "creates a refund successfully" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/poslink/v1/refunds"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]

        json_response(conn, 201, %{
          "refund_id" => "refund-uuid-1",
          "status" => "SUCCESSFUL"
        })
      end)

      params = %{
        "store_id" => "store-uuid-1",
        "payment_request_id" => "payment-uuid-9012"
      }

      assert {:ok, response} = Refund.create(params)
      assert response["status"] == "SUCCESSFUL"
      assert response["refund_id"] == "refund-uuid-1"
    end

    test "returns pending on 202" do
      stub_api(fn conn ->
        json_response(conn, 202, %{"refund_id" => "refund-uuid-2", "status" => "PENDING"})
      end)

      params = %{"store_id" => "store-uuid-1", "payment_request_id" => "payment-uuid-9012"}
      assert {:ok, response} = Refund.create(params)
      assert response["status"] == "PENDING"
    end

    test "accepts a custom idempotency key" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["my-refund-ref"]
        json_response(conn, 201, %{"refund_id" => "refund-uuid-3", "status" => "SUCCESSFUL"})
      end)

      params = %{"store_id" => "store-uuid-1", "payment_request_id" => "payment-uuid-9012"}
      assert {:ok, _} = Refund.create(params, idempotency_key: "my-refund-ref")
    end

    test "returns Teya.Error on 404 when payment not found" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Payment request not found")
      end)

      assert {:error, %Error{status: 404}} =
               Refund.create(%{"payment_request_id" => "bad-uuid"})
    end

    test "returns Teya.Error on 409 for duplicate refund" do
      stub_api(fn conn ->
        error_response(conn, 409, "CONFLICT", "Refund already processed")
      end)

      assert {:error, %Error{code: "CONFLICT", status: 409}} =
               Refund.create(%{
                 "store_id" => "store-uuid-1",
                 "payment_request_id" => "payment-uuid-9012"
               })
    end
  end
end
