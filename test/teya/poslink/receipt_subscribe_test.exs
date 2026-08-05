defmodule Teya.POSLink.ReceiptSubscribeTest do
  use Teya.POSLink.SubscribeCase, async: false

  alias Teya.Error
  alias Teya.POSLink.Receipt

  defp sse_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp stub_receipt_sse(receipt_id, body) do
    stub_sse(fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/poslink/v1/receipt-requests/#{receipt_id}/status"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  describe "subscribe_status/2" do
    test "returns {:ok, task}" do
      receipt_id = "receipt-uuid-1"
      stub_receipt_sse(receipt_id, sse_event("full", %{"status" => "ENQUEUED"}))

      assert {:ok, %Task{}} = Receipt.subscribe_status(receipt_id, self())
      assert_receive {:poslink_receipt, ^receipt_id, _, _}, 500
    end

    test "sends a full event to the caller" do
      receipt_id = "receipt-uuid-1"
      data = %{"status" => "PRINTED", "receipt_id" => receipt_id}
      stub_receipt_sse(receipt_id, sse_event("full", data))

      {:ok, _task} = Receipt.subscribe_status(receipt_id, self())

      assert_receive {:poslink_receipt, ^receipt_id, "full", received_data}, 500
      assert received_data["status"] == "PRINTED"
    end

    test "sends multiple status transitions in sequence" do
      receipt_id = "receipt-uuid-2"

      body =
        sse_event("full", %{"status" => "ENQUEUED"}) <>
          sse_event("diff", %{"status" => "PRINTING"}) <>
          sse_event("diff", %{"status" => "PRINTED"})

      stub_receipt_sse(receipt_id, body)

      {:ok, _task} = Receipt.subscribe_status(receipt_id, self())

      assert_receive {:poslink_receipt, ^receipt_id, "full", %{"status" => "ENQUEUED"}}, 500
      assert_receive {:poslink_receipt, ^receipt_id, "diff", %{"status" => "PRINTING"}}, 500
      assert_receive {:poslink_receipt, ^receipt_id, "diff", %{"status" => "PRINTED"}}, 500
    end

    test "sends poslink_receipt_error on non-200 response" do
      receipt_id = "receipt-uuid-3"

      stub_sse(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"code" => "NOT_FOUND", "description" => "Receipt not found"})
      end)

      {:ok, _task} = Receipt.subscribe_status(receipt_id, self())

      assert_receive {:poslink_receipt_error, ^receipt_id, %Error{status: 404}}, 500
    end

    test "sends poslink_receipt_error on transport failure" do
      receipt_id = "receipt-uuid-4"

      stub_sse(fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      {:ok, _task} = Receipt.subscribe_status(receipt_id, self())

      assert_receive {:poslink_receipt_error, ^receipt_id, %Req.TransportError{reason: :closed}},
                     500
    end

    test "sends poslink_receipt_error when the token fetch fails" do
      receipt_id = "receipt-uuid-5"

      stub_auth(fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      {:ok, _task} = Receipt.subscribe_status(receipt_id, self())

      assert_receive {:poslink_receipt_error, ^receipt_id,
                      %Req.TransportError{reason: :econnrefused}},
                     500
    end
  end
end
