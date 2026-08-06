defmodule Teya.POSLink.PaymentSubscribeTest do
  use Teya.POSLink.SubscribeCase, async: false

  alias Teya.Error
  alias Teya.POSLink.Payment

  defp sse_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp stub_payment_sse(body) do
    stub_sse(fn conn ->
      assert conn.method == "GET"
      assert String.starts_with?(conn.request_path, "/poslink/v2/payment-requests/")
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  describe "subscribe/2" do
    test "returns {:ok, task}" do
      stub_payment_sse(sse_event("full", %{"status" => "NEW"}))

      assert {:ok, %Task{}} = Payment.subscribe("pr-uuid-1", self())
      assert_receive {:poslink_payment, "pr-uuid-1", _, _}, 500
    end

    test "sends a full event to the caller" do
      payment_id = "pr-uuid-1"
      data = %{"status" => "SUCCESSFUL", "payment_request_id" => payment_id}
      stub_payment_sse(sse_event("full", data))

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment, ^payment_id, "full", received_data}, 500
      assert received_data["status"] == "SUCCESSFUL"
    end

    test "sends a diff event to the caller" do
      payment_id = "pr-uuid-2"
      stub_payment_sse(sse_event("diff", %{"status" => "IN_PROGRESS"}))

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment, ^payment_id, "diff", data}, 500
      assert data["status"] == "IN_PROGRESS"
    end

    test "sends multiple events in sequence" do
      payment_id = "pr-uuid-3"

      body =
        sse_event("full", %{"status" => "NEW"}) <>
          sse_event("diff", %{"status" => "IN_PROGRESS"}) <>
          sse_event("diff", %{"status" => "SUCCESSFUL"})

      stub_payment_sse(body)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment, ^payment_id, "full", %{"status" => "NEW"}}, 500
      assert_receive {:poslink_payment, ^payment_id, "diff", %{"status" => "IN_PROGRESS"}}, 500
      assert_receive {:poslink_payment, ^payment_id, "diff", %{"status" => "SUCCESSFUL"}}, 500
    end

    test "sends poslink_payment_error on non-200 response" do
      payment_id = "pr-uuid-4"

      stub_sse(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"code" => "NOT_FOUND", "description" => "Payment not found"})
      end)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment_error, ^payment_id, %Error{status: 404}}, 500
    end

    test "sends poslink_payment_error on transport failure" do
      payment_id = "pr-uuid-5"

      stub_sse(fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment_error, ^payment_id, %Req.TransportError{reason: :timeout}},
                     500
    end

    test "discards SSE events with non-JSON data" do
      payment_id = "pr-uuid-6"

      body =
        "event: full\ndata: not-json\n\n" <>
          sse_event("full", %{"status" => "NEW"})

      stub_payment_sse(body)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment, ^payment_id, "full", %{"status" => "NEW"}}, 500
      refute_receive {:poslink_payment, ^payment_id, "full", _other}, 100
    end

    test "ignores keepalive frames that carry no data" do
      payment_id = "pr-uuid-7"

      body =
        ": keepalive\n\n" <>
          "event: ping\n\n" <>
          sse_event("full", %{"status" => "NEW"})

      stub_payment_sse(body)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment, ^payment_id, "full", %{"status" => "NEW"}}, 500
      refute_receive {:poslink_payment, ^payment_id, _type, _data}, 100
    end

    test "sends poslink_payment_error when the token fetch fails" do
      payment_id = "pr-uuid-8"

      stub_auth(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "invalid_client"})
      end)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment_error, ^payment_id, %Req.Response{status: 401}}, 500
    end
  end
end
