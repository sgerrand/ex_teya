defmodule Teya.CheckoutTest do
  use Teya.APICase, async: false

  describe "create_session/2" do
    test "returns session_id and session_url on success" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/checkout/sessions"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]

        json_response(conn, 201, %{
          "session_id" => "sess_abc123",
          "session_url" => "https://checkout.teya.com/sess_abc123"
        })
      end)

      params = %{"amount" => %{"currency" => "GBP", "value" => 1000}, "type" => "SALE"}
      assert {:ok, response} = Teya.Checkout.create_session(params)
      assert response["session_id"] == "sess_abc123"
      assert response["session_url"] == "https://checkout.teya.com/sess_abc123"
    end

    test "accepts a custom idempotency key" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["my-order-ref"]

        json_response(conn, 201, %{
          "session_id" => "sess_xyz",
          "session_url" => "https://checkout.teya.com/sess_xyz"
        })
      end)

      params = %{"amount" => %{"currency" => "EUR", "value" => 500}, "type" => "SALE"}
      assert {:ok, _} = Teya.Checkout.create_session(params, idempotency_key: "my-order-ref")
    end

    test "returns Teya.Error on 400 bad request" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Invalid amount value")
      end)

      params = %{"amount" => %{"currency" => "GBP", "value" => -1}, "type" => "SALE"}

      assert {:error, %Teya.Error{code: "BAD_REQUEST", status: 400}} =
               Teya.Checkout.create_session(params)
    end

    test "returns Teya.Error on 401 unauthorized" do
      stub_api(fn conn ->
        error_response(conn, 401, "UNAUTHORISED", "Invalid token")
      end)

      params = %{"amount" => %{"currency" => "GBP", "value" => 100}, "type" => "SALE"}

      assert {:error, %Teya.Error{code: "UNAUTHORISED", status: 401}} =
               Teya.Checkout.create_session(params)
    end

    test "returns Teya.Error on 429 rate limit" do
      stub_api(fn conn ->
        error_response(conn, 429, "TOO_MANY_REQUESTS", "Rate limit exceeded")
      end)

      params = %{"amount" => %{"currency" => "GBP", "value" => 100}, "type" => "SALE"}

      assert {:error, %Teya.Error{code: "TOO_MANY_REQUESTS", status: 429}} =
               Teya.Checkout.create_session(params)
    end
  end

  describe "get_session/2" do
    test "returns session details" do
      stub_api(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/checkout/sessions/sess_abc123"

        json_response(conn, 200, %{
          "session_id" => "sess_abc123",
          "session_status" => "COMPLETED",
          "payment_status" => "SUCCESS",
          "type" => "SALE"
        })
      end)

      assert {:ok, response} = Teya.Checkout.get_session("sess_abc123")
      assert response["session_status"] == "COMPLETED"
      assert response["payment_status"] == "SUCCESS"
    end

    test "returns Teya.Error on 404 not found" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Session not found")
      end)

      assert {:error, %Teya.Error{status: 404}} = Teya.Checkout.get_session("nonexistent")
    end
  end
end
