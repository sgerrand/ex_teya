defmodule Teya.PayByLinkTest do
  use Teya.APICase, async: false

  describe "create/2" do
    test "returns payment_link_id and payment_link URL" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/payment-links"

        json_response(conn, 201, %{
          "payment_link_id" => "pbl-uuid-1234",
          "payment_link" => "https://pay.teya.com/pbl-uuid-1234"
        })
      end)

      params = %{"amount" => %{"currency" => "GBP", "value" => 5000}}
      assert {:ok, response} = Teya.PayByLink.create(params)
      assert response["payment_link_id"] == "pbl-uuid-1234"
      assert response["payment_link"] == "https://pay.teya.com/pbl-uuid-1234"
    end

    test "returns Teya.Error on bad request" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Invalid currency")
      end)

      params = %{"amount" => %{"currency" => "INVALID", "value" => 100}}

      assert {:error, %Teya.Error{code: "BAD_REQUEST", status: 400}} =
               Teya.PayByLink.create(params)
    end
  end

  describe "get/2" do
    test "retrieves payment link details" do
      stub_api(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/payment-links/pbl-uuid-1234"

        json_response(conn, 200, %{
          "payment_link_id" => "pbl-uuid-1234",
          "status" => "VALID",
          "amount" => %{"currency" => "GBP", "value" => 5000}
        })
      end)

      assert {:ok, response} = Teya.PayByLink.get("pbl-uuid-1234")
      assert response["status"] == "VALID"
    end

    test "returns Teya.Error on 404" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Payment link not found")
      end)

      assert {:error, %Teya.Error{status: 404}} = Teya.PayByLink.get("nonexistent")
    end
  end

  describe "update/3" do
    test "updates payment link expiry" do
      stub_api(fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/v2/payment-links/pbl-uuid-1234"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []

        json_response(conn, 200, %{
          "payment_link_id" => "pbl-uuid-1234",
          "status" => "VALID",
          "expires_at" => "2024-12-31T23:59:59Z"
        })
      end)

      params = %{"expires_at" => "2024-12-31T23:59:59Z"}
      assert {:ok, response} = Teya.PayByLink.update("pbl-uuid-1234", params)
      assert response["expires_at"] == "2024-12-31T23:59:59Z"
    end
  end
end
