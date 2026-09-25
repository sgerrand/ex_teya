defmodule Teya.MotoTest do
  use Teya.APICase, async: false

  alias Teya.Error

  @params %{
    "type" => "SALE",
    "amounts" => %{"amount" => 2500, "currency" => "GBP"},
    "card_details" => %{
      "encrypted_card_data" => "a1b2c3",
      "encryption_key_id" => "key-1",
      "encryption_ksn" => "ksn-1"
    },
    "transacted_at" => "2026-09-25T10:30:00Z"
  }

  describe "create/2" do
    test "sends the transaction and returns its result" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/transactions/moto"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]
        assert [_key] = Plug.Conn.get_req_header(conn, "idempotency-key")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == @params

        json_response(conn, 201, %{
          "transaction_id" => "txn-1",
          "status" => "SUCCESS",
          "processed_at" => "2026-09-25T10:30:01Z"
        })
      end)

      assert {:ok, %{"status" => "SUCCESS", "transaction_id" => "txn-1"}} =
               Teya.Moto.create(@params)
    end

    test "sends the idempotency key it is given" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["order-42"]
        json_response(conn, 201, %{"transaction_id" => "txn-2", "status" => "PENDING"})
      end)

      assert {:ok, %{"status" => "PENDING"}} =
               Teya.Moto.create(@params, idempotency_key: "order-42")
    end

    test "returns a declined card as a Teya.Error" do
      stub_api(fn conn ->
        error_response(conn, 400, "CARD_DECLINED", "The card was declined")
      end)

      assert {:error, %Error{code: "CARD_DECLINED", status: 400}} = Teya.Moto.create(@params)
    end
  end
end
