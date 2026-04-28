defmodule Teya.RefundTest do
  use Teya.APICase, async: false

  describe "create/2" do
    test "creates a refund successfully" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v3/refunds"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []

        json_response(conn, 201, %{"status" => "SUCCESS", "refund_id" => "ref-uuid-1234"})
      end)

      params = %{
        "transaction_id" => "txn-uuid-9012",
        "amount" => %{"currency" => "GBP", "value" => 500}
      }

      assert {:ok, response} = Teya.Refund.create(params)
      assert response["status"] == "SUCCESS"
    end

    test "returns pending on 202" do
      stub_api(fn conn ->
        json_response(conn, 202, %{"status" => "PENDING", "refund_id" => "ref-uuid-1234"})
      end)

      params = %{"transaction_id" => "txn-uuid-9012"}
      assert {:ok, response} = Teya.Refund.create(params)
      assert response["status"] == "PENDING"
    end

    test "returns Teya.Error on 404" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Transaction not found")
      end)

      assert {:error, %Teya.Error{status: 404}} = Teya.Refund.create(%{"transaction_id" => "bad"})
    end

    test "returns Teya.Error on 409 duplicate refund" do
      stub_api(fn conn ->
        error_response(conn, 409, "CONFLICT", "Refund already processed")
      end)

      assert {:error, %Teya.Error{status: 409}} =
               Teya.Refund.create(%{"transaction_id" => "txn-uuid-9012"},
                 idempotency_key: "duplicate-refund-key"
               )
    end
  end
end
