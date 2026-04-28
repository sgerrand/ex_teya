defmodule Teya.TransactionTest do
  use Teya.APICase, async: false

  @card_params %{
    "amount" => %{"currency" => "GBP", "value" => 2000},
    "initiator" => "CUSTOMER",
    "payment_method" => %{
      "type" => "CARD",
      "card" => %{
        "number" => "4111111111111111",
        "expiry_month" => "12",
        "expiry_year" => "2028",
        "cvc" => "123"
      }
    },
    "store_id" => "store-uuid-1234",
    "type" => "SALE"
  }

  describe "create/2" do
    test "returns ONLINE_TRANSACTION on success" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v3/transactions/online"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []

        json_response(conn, 201, %{
          "type" => "ONLINE_TRANSACTION",
          "online_transaction" => %{
            "authentication_id" => "auth-uuid-5678",
            "transaction_id" => "txn-uuid-9012",
            "status" => "SUCCESS",
            "created_at" => "2024-01-01T12:00:00Z"
          }
        })
      end)

      assert {:ok, response} = Teya.Transaction.create(@card_params)
      assert response["type"] == "ONLINE_TRANSACTION"
      assert response["online_transaction"]["status"] == "SUCCESS"
    end

    test "returns REDIRECT_TRANSACTION_RESPONSE for 3DS challenge" do
      stub_api(fn conn ->
        json_response(conn, 202, %{
          "type" => "REDIRECT_TRANSACTION_RESPONSE",
          "redirect_transaction_response" => %{
            "redirect_url" => "https://3ds.issuer.com/challenge",
            "authentication_id" => "auth-uuid-3ds"
          }
        })
      end)

      assert {:ok, response} = Teya.Transaction.create(@card_params)
      assert response["type"] == "REDIRECT_TRANSACTION_RESPONSE"
    end

    test "returns Teya.Error on card decline" do
      stub_api(fn conn ->
        error_response(conn, 422, "CARD_DECLINED", "Card was declined")
      end)

      assert {:error, %Teya.Error{code: "CARD_DECLINED", status: 422}} =
               Teya.Transaction.create(@card_params)
    end

    test "returns Teya.Error on 409 duplicate idempotency key" do
      stub_api(fn conn ->
        error_response(conn, 409, "CONFLICT", "Request already processed")
      end)

      assert {:error, %Teya.Error{status: 409}} =
               Teya.Transaction.create(@card_params, idempotency_key: "duplicate-key")
    end
  end

  describe "get/2" do
    test "retrieves a transaction by authentication_id" do
      stub_api(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/transactions/online/auth-uuid-5678"

        json_response(conn, 200, %{
          "authentication_id" => "auth-uuid-5678",
          "transaction_id" => "txn-uuid-9012",
          "status" => "SUCCESS"
        })
      end)

      assert {:ok, response} = Teya.Transaction.get("auth-uuid-5678")
      assert response["status"] == "SUCCESS"
    end

    test "returns Teya.Error on 404" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Transaction not found")
      end)

      assert {:error, %Teya.Error{status: 404}} = Teya.Transaction.get("nonexistent-auth-id")
    end
  end
end
