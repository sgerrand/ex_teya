defmodule Teya.DCCTest do
  use Teya.APICase, async: false

  describe "quote/1" do
    test "returns an exchange rate offer for an eligible card" do
      stub_dcc(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/fx/v3/dcc"
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        json_response(conn, 200, %{
          "quote_id" => "quote-uuid-1234",
          "quoted_at" => "2026-05-02T10:00:00Z",
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
      stub_dcc(fn conn ->
        json_response(conn, 200, %{
          "quote_id" => "quote-uuid-5678",
          "quoted_at" => "2026-05-02T10:00:00Z",
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
      stub_dcc(fn conn ->
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
      stub_dcc(fn conn ->
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
      stub_dcc(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Invalid card_first9 length")
      end)

      assert {:error, %Teya.Error{status: 400, code: "BAD_REQUEST"}} =
               Teya.DCC.quote(%{})
    end

    test "returns transport error on network failure" do
      stub_dcc(fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Teya.DCC.quote(%{
                 "store_id" => "s",
                 "card_first9" => "411111111",
                 "base_amount" => 1000,
                 "base_currency" => "GBP"
               })
    end
  end
end
