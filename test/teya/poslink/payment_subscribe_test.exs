defmodule Teya.POSLink.PaymentSubscribeTest do
  use Teya.POSLink.SubscribeCase, async: false

  alias Teya.Error
  alias Teya.POSLink.Payment

  defp sse_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  # Kills the tasks get/2 started, identified as the ones that were not
  # running before the call.
  defp kill_new_tasks(before, attempts \\ 100) do
    started = Task.Supervisor.children(Teya.TaskSupervisor) -- before

    cond do
      started != [] -> Enum.each(started, &Process.exit(&1, :kill))
      attempts > 0 -> Process.sleep(10) && kill_new_tasks(before, attempts - 1)
      true -> flunk("get/2 started no task under Teya.TaskSupervisor")
    end
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

    test "stops accumulating an oversized error body" do
      payment_id = "pr-uuid-11"
      chunk = String.duplicate("x", 4_096)

      stub_sse(fn conn ->
        conn = Plug.Conn.send_chunked(conn, 500)

        Enum.reduce(1..5, conn, fn _i, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)

      {:ok, _task} = Payment.subscribe(payment_id, self())

      assert_receive {:poslink_payment_error, ^payment_id, error}, 500
      assert %Error{status: 500} = error
      assert byte_size(error.message) <= 512
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

    test "leaves messages belonging to another subscription alone" do
      payment_id = "pr-uuid-23"
      stub_payment_sse(sse_event("full", %{"status" => "NEW"}))

      # As if subscribe/2 were already streaming this payment to the caller.
      send(self(), {:poslink_payment, payment_id, "full", %{"status" => "IN_PROGRESS"}})
      send(self(), {:poslink_payment, payment_id, "diff", %{"status" => "SUCCESSFUL"}})

      assert {:ok, %{"status" => "NEW"}} = Payment.get(payment_id)

      assert_received {:poslink_payment, ^payment_id, "full", %{"status" => "IN_PROGRESS"}}
      assert_received {:poslink_payment, ^payment_id, "diff", %{"status" => "SUCCESSFUL"}}
    end

    test "waits for a snapshot rather than returning a diff" do
      payment_id = "pr-uuid-24"

      body =
        sse_event("diff", %{"status" => "IN_PROGRESS"}) <>
          sse_event("full", %{"status" => "SUCCESSFUL", "gateway_payment_id" => "gw-1"})

      stub_payment_sse(body)

      assert {:ok, %{"status" => "SUCCESSFUL", "gateway_payment_id" => "gw-1"}} =
               Payment.get(payment_id)
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

    test "reports the reason when the task waiting for the snapshot is killed" do
      payment_id = "pr-uuid-25"

      stub_sse(fn conn ->
        Process.sleep(1_000)
        Plug.Conn.send_resp(conn, 200, "")
      end)

      caller = self()
      before = Task.Supervisor.children(Teya.TaskSupervisor)

      # Task.start keeps $callers, so the stream task still finds the stub.
      {:ok, _pid} =
        Task.start(fn -> send(caller, {:got, Payment.get(payment_id, timeout: 5_000)}) end)

      kill_new_tasks(before)

      assert_receive {:got, {:error, :killed}}, 2_000
    end

    test "returns a keepalive-free snapshot" do
      payment_id = "pr-uuid-26"

      body =
        "event: ping\ndata: {\"keepalive\":true}\n\n" <>
          sse_event("full", %{"status" => "NEW", "gateway_payment_id" => "gw-2"})

      stub_payment_sse(body)

      assert {:ok, %{"status" => "NEW", "gateway_payment_id" => "gw-2"}} = Payment.get(payment_id)
    end

    test "reports a crashed stream without waiting out the timeout" do
      payment_id = "pr-uuid-28"

      stub_sse(fn _conn -> raise "boom" end)

      {elapsed_us, result} = :timer.tc(fn -> Payment.get(payment_id, timeout: 10_000) end)

      assert {:error, _reason} = result
      assert elapsed_us < 5_000_000
    end

    test "treats an event with no name as a snapshot" do
      payment_id = "pr-uuid-30"
      stub_payment_sse("data: #{Jason.encode!(%{"status" => "NEW"})}\n\n")

      assert {:ok, %{"status" => "NEW"}} = Payment.get(payment_id)
    end

    test "accepts :infinity as the timeout" do
      payment_id = "pr-uuid-27"
      stub_payment_sse(sse_event("full", %{"status" => "NEW"}))

      assert {:ok, %{"status" => "NEW"}} = Payment.get(payment_id, timeout: :infinity)
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
