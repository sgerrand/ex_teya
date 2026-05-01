defmodule Teya.ReversalTest do
  use Teya.APICase, async: false

  describe "create/2" do
    test "reverses a transaction by transaction_id" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/reversals"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []

        json_response(conn, 200, %{
          "status" => "SUCCESS",
          "reversal_amount" => %{"amount" => 1000, "currency" => "GBP"}
        })
      end)

      params = %{
        "reversal_reason" => "CARD_REVERSAL",
        "transaction_id" => "txn-uuid-9012"
      }

      assert {:ok, response} = Teya.Reversal.create(params)
      assert response["status"] == "SUCCESS"
    end

    test "reverses a transaction by idempotency_key reference" do
      stub_api(fn conn ->
        json_response(conn, 200, %{
          "status" => "SUCCESS",
          "reversal_amount" => %{"amount" => 500, "currency" => "GBP"}
        })
      end)

      params = %{
        "reversal_reason" => "COMMUNICATION_REVERSAL",
        "idempotency_key" => "original-request-key"
      }

      assert {:ok, response} = Teya.Reversal.create(params)
      assert response["status"] == "SUCCESS"
    end

    test "returns acknowledged on 202" do
      stub_api(fn conn ->
        json_response(conn, 202, %{
          "status" => "ACKNOWLEDGED",
          "reversal_amount" => %{"amount" => 1000, "currency" => "GBP"}
        })
      end)

      params = %{"reversal_reason" => "CARD_REMOVED", "transaction_id" => "txn-uuid-9012"}
      assert {:ok, response} = Teya.Reversal.create(params)
      assert response["status"] == "ACKNOWLEDGED"
    end

    test "returns Teya.Error on 400" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Missing reversal_reason")
      end)

      assert {:error, %Teya.Error{status: 400, code: "BAD_REQUEST"}} =
               Teya.Reversal.create(%{})
    end

    test "returns Teya.Error when transaction cannot be reversed" do
      stub_api(fn conn ->
        error_response(
          conn,
          409,
          "TRANSACTION_CANNOT_BE_REVERSED",
          "Transaction has already settled"
        )
      end)

      assert {:error, %Teya.Error{status: 409, code: "TRANSACTION_CANNOT_BE_REVERSED"}} =
               Teya.Reversal.create(%{
                 "reversal_reason" => "CARD_REVERSAL",
                 "transaction_id" => "settled-txn"
               })
    end
  end
end
