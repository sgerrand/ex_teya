defmodule Teya.CardPresentTest do
  use Teya.APICase, async: false

  describe "create/2" do
    test "processes a card-present transaction" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/transactions/card-present"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []

        json_response(conn, 201, %{
          "transaction_id" => "txn-uuid-1234",
          "card_acceptor_id" => "mid-5678",
          "status" => "SUCCESS",
          "issuer_result" => %{"approval_code" => "123456"},
          "processed_at" => "2025-05-01T12:00:00Z"
        })
      end)

      params = %{
        "type" => "SALE",
        "entry_mode" => "CONTACT_EMV",
        "amounts" => %{"amount" => 1000, "currency" => "GBP"},
        "emv_data" => "9F2608AABBCCDD",
        "track_data" => %{
          "encryption_key_id" => "key-1",
          "encrypted_track" => "enctrack",
          "encryption_ksn" => "ksn-1"
        },
        "transacted_at" => "2025-05-01T12:00:00Z"
      }

      assert {:ok, response} = Teya.CardPresent.create(params)
      assert response["status"] == "SUCCESS"
    end

    test "returns pending status" do
      stub_api(fn conn ->
        json_response(conn, 201, %{
          "transaction_id" => "txn-uuid-1234",
          "card_acceptor_id" => "mid-5678",
          "status" => "PENDING",
          "issuer_result" => %{},
          "processed_at" => "2025-05-01T12:00:00Z"
        })
      end)

      assert {:ok, response} = Teya.CardPresent.create(%{"type" => "SALE"})
      assert response["status"] == "PENDING"
    end

    test "returns Teya.Error on 400" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Invalid entry mode")
      end)

      assert {:error, %Teya.Error{status: 400, code: "BAD_REQUEST"}} =
               Teya.CardPresent.create(%{})
    end

    test "returns Teya.Error on 409 conflict" do
      stub_api(fn conn ->
        error_response(conn, 409, "CONFLICT", "Duplicate transaction")
      end)

      assert {:error, %Teya.Error{status: 409}} =
               Teya.CardPresent.create(%{"type" => "SALE"}, idempotency_key: "duplicate-key")
    end
  end
end
