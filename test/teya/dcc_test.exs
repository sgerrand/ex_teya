defmodule Teya.DCCTest do
  use Teya.APICase, async: false

  describe "quote/2" do
    test "returns an exchange rate offer for an eligible card" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert Plug.Conn.get_req_header(conn, "user-agent") == [Teya.HTTP.user_agent()]
        assert conn.request_path == "/fx/v1/dcc/offers"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]
        # The FX spec documents no Idempotency-Key for this endpoint.
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []

        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body) == %{
                 "store_id" => "store-uuid-5678",
                 "card_first9" => "411111111",
                 "base_amount" => 1000,
                 "base_currency" => "GBP"
               }

        json_response(conn, 200, %{
          "quote_id" => "quote-uuid-1234",
          "exchange_rate" => "1.234567",
          "markup" => "2.5",
          "cardholder_currency" => "EUR",
          "cardholder_amount" => 1234
        })
      end)

      params = %{
        "store_id" => "store-uuid-5678",
        "card_first9" => "411111111",
        "base_amount" => 1000,
        "base_currency" => "GBP"
      }

      assert {:ok, offer} = Teya.DCC.quote(params)
      assert offer["quote_id"] == "quote-uuid-1234"
      assert offer["cardholder_currency"] == "EUR"
      assert offer["cardholder_amount"] == 1234
    end

    test "includes ecb_markup for EEA currencies" do
      stub_api(fn conn ->
        json_response(conn, 200, %{
          "quote_id" => "quote-uuid-5678",
          "exchange_rate" => "1.100000",
          "markup" => "2.0",
          "ecb_markup" => "1.5",
          "cardholder_currency" => "EUR",
          "cardholder_amount" => 1100
        })
      end)

      assert {:ok, offer} =
               Teya.DCC.quote(%{
                 "store_id" => "s",
                 "card_first9" => "411111111",
                 "base_amount" => 1000,
                 "base_currency" => "GBP"
               })

      assert offer["ecb_markup"] == "1.5"
    end

    test "returns Teya.Error for a non-eligible card" do
      stub_api(fn conn ->
        error_response(conn, 400, "NON_ELIGIBLE_CARD", "Card BIN is not eligible for DCC")
      end)

      assert {:error, %Teya.Error{status: 400, code: "NON_ELIGIBLE_CARD"}} =
               Teya.DCC.quote(%{
                 "store_id" => "store-uuid-5678",
                 "card_first9" => "411111111",
                 "base_amount" => 1000,
                 "base_currency" => "GBP"
               })
    end

    test "returns Teya.Error when cardholder currency matches base currency" do
      stub_api(fn conn ->
        error_response(conn, 400, "SAME_CURRENCY", "Cardholder currency matches base currency")
      end)

      assert {:error, %Teya.Error{status: 400, code: "SAME_CURRENCY"}} =
               Teya.DCC.quote(%{
                 "store_id" => "store-uuid-5678",
                 "card_first9" => "411111111",
                 "base_amount" => 1000,
                 "base_currency" => "GBP",
                 "cardholder_currency" => "GBP"
               })
    end

    test "returns Teya.Error on 400 bad request" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Invalid card_first9 length")
      end)

      assert {:error, %Teya.Error{status: 400, code: "BAD_REQUEST"}} =
               Teya.DCC.quote(%{})
    end

    test "returns transport error on network failure" do
      stub_api(fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Teya.Error{reason: %Req.TransportError{reason: :timeout}}} =
               Teya.DCC.quote(%{
                 "store_id" => "s",
                 "card_first9" => "411111111",
                 "base_amount" => 1000,
                 "base_currency" => "GBP"
               })
    end
  end

  describe "errors" do
    test "keeps the fields the FX API lists as invalid_params" do
      stub_api(fn conn ->
        json_response(conn, 400, %{
          "code" => "BAD_REQUEST",
          "description" => "Invalid request",
          "invalid_params" => [%{"path" => "card_first9", "reason" => "too short"}]
        })
      end)

      assert {:error, %Teya.Error{invalid_parameters: [%{"path" => "card_first9"}]}} =
               Teya.DCC.quote(%{"card_first9" => "41"})
    end

    test "keeps a filled invalid_params list over an empty invalid_parameters" do
      stub_api(fn conn ->
        json_response(conn, 400, %{
          "code" => "BAD_REQUEST",
          "invalid_parameters" => [],
          "invalid_params" => [%{"path" => "card_first9", "reason" => "too short"}]
        })
      end)

      assert {:error, %Teya.Error{invalid_parameters: [%{"path" => "card_first9"}]}} =
               Teya.DCC.quote(%{"card_first9" => "41"})
    end

    test "keeps the invalid_params list when invalid_parameters is not a list" do
      stub_api(fn conn ->
        json_response(conn, 400, %{
          "code" => "BAD_REQUEST",
          "invalid_parameters" => "see invalid_params",
          "invalid_params" => [%{"path" => "base_amount", "reason" => "negative"}]
        })
      end)

      assert {:error, %Teya.Error{invalid_parameters: [%{"path" => "base_amount"}]}} =
               Teya.DCC.quote(%{"base_amount" => -1})
    end
  end

  describe "idempotency key" do
    test "is not sent, even when the caller gives one" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
        json_response(conn, 200, %{"quote_id" => "q-1"})
      end)

      assert {:ok, _} = Teya.DCC.quote(%{"store_id" => "s-1"}, idempotency_key: "order-1")
    end

    test "is not sent when one is set in :req_options" do
      Teya.TestEnv.add(:req_options, headers: [{"idempotency-key", "configured"}])

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
        json_response(conn, 200, %{"quote_id" => "q-1"})
      end)

      assert {:ok, _} = Teya.DCC.quote(%{"store_id" => "s-1"})
    end
  end
end
