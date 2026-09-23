defmodule Teya.POSLink.PaymentSubscribeTest do
  use Teya.POSLink.SubscribeCase, async: false

  alias Teya.Error
  alias Teya.POSLink.Payment

  defp sse_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  # Restores the setting by removing it, since it has no value by default and
  # putting nil back would be read as a cap of nil.
  defp put_error_body_cap(bytes) do
    original = Application.fetch_env(:teya, :sse_max_error_body_bytes)
    Application.put_env(:teya, :sse_max_error_body_bytes, bytes)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:teya, :sse_max_error_body_bytes, value)
        :error -> Application.delete_env(:teya, :sse_max_error_body_bytes)
      end
    end)
  end

  defp stub_payment_sse(body) do
    stub_sse(fn conn ->
      assert conn.method == "GET"
      assert String.starts_with?(conn.request_path, "/poslink/v3/payment-requests/")
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

      assert_receive {:poslink_payment_error, ^payment_id, error}, 500

      assert %Error{code: "NOT_FOUND", message: "Payment not found", status: 404} = error
    end

    test "keeps a non-JSON error body in the message" do
      payment_id = "pr-uuid-9"

      stub_sse(fn conn ->
        Plug.Conn.send_resp(conn, 502, "upstream unavailable")
      end)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment_error, ^payment_id, error}, 500
      assert %Error{code: nil, status: 502} = error
      assert error.message =~ "upstream unavailable"
    end

    test "sends poslink_payment_error on a 2xx status that is not 200" do
      payment_id = "pr-uuid-10"

      stub_sse(fn conn ->
        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"code" => "ACCEPTED", "description" => "Stream not ready"})
      end)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment_error, ^payment_id, error}, 500
      assert %Error{code: "ACCEPTED", message: "Stream not ready", status: 202} = error
    end

    test "keeps the code of a large JSON error body" do
      payment_id = "pr-uuid-13"

      stub_sse(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "code" => "BAD_REQUEST",
          "description" => "Invalid input",
          "invalid_parameters" =>
            Enum.map(1..500, &%{"name" => "field_#{&1}", "reason" => "must be present"})
        })
      end)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment_error, ^payment_id, error}, 500
      assert %Error{code: "BAD_REQUEST", message: "Invalid input", status: 400} = error
    end

    test "cuts an error body that runs past the cap" do
      payment_id = "pr-uuid-11"
      put_error_body_cap(200)

      stub_sse(fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{
          "code" => "INTERNAL_SERVER_ERROR",
          "description" => String.duplicate("x", 5_000)
        })
      end)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment_error, ^payment_id, error}, 500

      # Cut mid-JSON, so it no longer decodes: the status survives, the code
      # does not, and only what fitted in the cap is quoted.
      assert %Error{code: nil, status: 500} = error
      assert error.message =~ "INTERNAL_SERVER_ERROR"
      assert byte_size(error.message) < 5_000
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

  describe "get/2" do
    test "returns the first snapshot and closes the stream" do
      payment_id = "pr-uuid-20"

      body =
        sse_event("full", %{"payment_request_id" => payment_id, "status" => "IN_PROGRESS"}) <>
          sse_event("diff", %{"status" => "SUCCESSFUL"})

      stub_payment_sse(body)

      assert {:ok, %{"status" => "IN_PROGRESS"}} = Payment.get(payment_id)
      refute_received {:poslink_payment, ^payment_id, _type, _data}
    end

    test "discards a stream error that arrives after the snapshot" do
      payment_id = "pr-uuid-23"
      stub_payment_sse(sse_event("full", %{"status" => "NEW"}))

      send(self(), {:poslink_payment, payment_id, "full", %{"status" => "IN_PROGRESS"}})
      send(self(), {:poslink_payment_error, payment_id, :closed})

      assert {:ok, %{"status" => "IN_PROGRESS"}} = Payment.get(payment_id)
      refute_received {:poslink_payment_error, ^payment_id, _reason}
    end

    test "returns Teya.Error when the payment is not found" do
      stub_sse(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Payment request not found")
      end)

      assert {:error,
              %Error{code: "NOT_FOUND", message: "Payment request not found", status: 404}} =
               Payment.get("nonexistent")
    end

    test "returns :no_event when the stream closes without an event" do
      stub_payment_sse("")

      assert {:error, :no_event} = Payment.get("pr-uuid-21")
    end

    test "returns :timeout when no event arrives in time" do
      stub_sse(fn conn ->
        Process.sleep(500)
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert {:error, :timeout} = Payment.get("pr-uuid-22", timeout: 50)
    end
  end
end
