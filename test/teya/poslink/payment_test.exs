defmodule Teya.POSLink.PaymentTest do
  use Teya.APICase, async: false

  describe "create/2" do
    test "creates a payment request successfully" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/poslink/v2/payment-requests"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]

        json_response(conn, 201, %{
          "payment_request_id" => "pr-uuid-1",
          "status" => "NEW"
        })
      end)

      params = %{
        "store_id" => "store-uuid-1",
        "terminal_id" => "term-uuid-1",
        "requested_amount" => %{"amount" => 1000, "currency" => "GBP"}
      }

      assert {:ok, response} = Teya.POSLink.Payment.create(params)
      assert response["payment_request_id"] == "pr-uuid-1"
      assert response["status"] == "NEW"
    end

    test "accepts a custom idempotency key" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["order-ref-42"]
        json_response(conn, 201, %{"payment_request_id" => "pr-uuid-2", "status" => "NEW"})
      end)

      params = %{
        "store_id" => "store-uuid-1",
        "terminal_id" => "term-uuid-1",
        "requested_amount" => %{"amount" => 500, "currency" => "EUR"}
      }

      assert {:ok, _} = Teya.POSLink.Payment.create(params, idempotency_key: "order-ref-42")
    end

    test "returns Teya.Error on 400 bad request" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Missing required field: store_id")
      end)

      assert {:error, %Teya.Error{code: "BAD_REQUEST", status: 400}} =
               Teya.POSLink.Payment.create(%{})
    end

    test "returns Teya.Error on 404 terminal not found" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Terminal not found")
      end)

      assert {:error, %Teya.Error{status: 404}} =
               Teya.POSLink.Payment.create(%{"terminal_id" => "bad-uuid"})
    end
  end

  describe "cancel/2" do
    test "cancels a payment request" do
      payment_id = "pr-uuid-1"

      stub_api(fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/poslink/v2/payment-requests/#{payment_id}"
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []

        json_response(conn, 200, %{
          "payment_request_id" => payment_id,
          "status" => "CANCELLING"
        })
      end)

      assert {:ok, response} = Teya.POSLink.Payment.cancel(payment_id)
      assert response["status"] == "CANCELLING"
    end

    test "returns Teya.Error on 404 when payment not found" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Payment request not found")
      end)

      assert {:error, %Teya.Error{status: 404}} = Teya.POSLink.Payment.cancel("nonexistent")
    end

    test "returns Teya.Error on 409 when payment already in terminal state" do
      stub_api(fn conn ->
        error_response(conn, 409, "CONFLICT", "Payment is already in a terminal state")
      end)

      assert {:error, %Teya.Error{code: "CONFLICT", status: 409}} =
               Teya.POSLink.Payment.cancel("pr-uuid-done")
    end
  end

  describe "list/1" do
    test "returns a list of payment requests" do
      stub_api(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/poslink/v1/payment-requests"

        json_response(conn, 200, %{
          "payment_requests" => [
            %{"payment_request_id" => "pr-uuid-1", "status" => "SUCCESSFUL"},
            %{"payment_request_id" => "pr-uuid-2", "status" => "FAILED"}
          ],
          "total" => 2
        })
      end)

      assert {:ok, response} = Teya.POSLink.Payment.list()
      assert length(response["payment_requests"]) == 2
    end

    test "passes query params to the API" do
      stub_api(fn conn ->
        assert conn.query_string =~ "status=SUCCESSFUL"
        json_response(conn, 200, %{"payment_requests" => [], "total" => 0})
      end)

      assert {:ok, _} = Teya.POSLink.Payment.list(params: [status: "SUCCESSFUL"])
    end

    test "returns Teya.Error on 400 invalid filter params" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "Invalid status value")
      end)

      assert {:error, %Teya.Error{status: 400}} =
               Teya.POSLink.Payment.list(params: [status: "INVALID"])
    end
  end
end
