defmodule Teya.PathSegmentTest do
  # Every function that puts a caller's id into a request path, checked in
  # one place: the id is encoded, so it cannot change which endpoint is
  # called, and one that cannot be a path segment at all raises in the
  # caller's process.
  use Teya.APICase, async: false

  import Teya.POSLink.SubscribeCase, only: [stub_sse: 1]

  alias Teya.{Capture, Checkout, PayByLink, Receipt, Token, Transaction}
  alias Teya.POSLink.{Payment, Store}
  alias Teya.POSLink.Receipt, as: POSLinkReceipt

  @id "a/b?c#d e"
  @encoded "a%2Fb%3Fc%23d%20e"

  # {expected path, call taking the id}
  defp requests do
    [
      {"/v2/transactions/online/#{@encoded}", &Transaction.get(&1)},
      {"/v1/payment-links/#{@encoded}", &PayByLink.get(&1)},
      {"/v2/payment-links/#{@encoded}", &PayByLink.update(&1, %{})},
      {"/v1/tokens/#{@encoded}", &Token.delete(&1, "store-uuid-1")},
      {"/v2/checkout/sessions/#{@encoded}", &Checkout.get_session(&1)},
      {"/v1/transactions/#{@encoded}/receipts", &Receipt.create(&1)},
      {"/v1/transactions/#{@encoded}/capture", &Capture.create(&1)},
      {"/poslink/v2/payment-requests/#{@encoded}", &Payment.cancel(&1)},
      {"/poslink/v3/payment-requests/#{@encoded}/receipt-text", &Payment.receipt_text(&1)},
      {"/poslink/v1/stores/#{@encoded}/terminals", &Store.list_terminals(&1)},
      {"/poslink/v1/stores/#{@encoded}/terminals/t-1/configs",
       &Store.terminal_configs(&1, "t-1")},
      {"/poslink/v1/stores/s-1/terminals/#{@encoded}/configs",
       &Store.terminal_configs("s-1", &1)},
      {"/poslink/v1/stores/#{@encoded}/configs/KEY", &Store.put_config(&1, "KEY", "on")},
      {"/poslink/v1/stores/s-1/configs/#{@encoded}", &Store.put_config("s-1", &1, "on")}
    ]
  end

  defp streams do
    [
      &Payment.get(&1),
      &Payment.subscribe(&1),
      &POSLinkReceipt.subscribe_status(&1)
    ]
  end

  # The stub runs in the task reading the stream, where a failed assertion
  # would only show up as a missing message. So it reports the path it was
  # asked for, and the test checks it.
  defp stub_stream do
    test = self()

    stub_sse(fn conn ->
      send(test, {:requested_path, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "event: full\ndata: {\"status\":\"NEW\"}\n\n")
    end)
  end

  defp assert_requested(expected_path) do
    assert_receive {:requested_path, path}, 500
    assert path == expected_path
  end

  test "every request encodes the id in its path" do
    for {expected_path, call} <- requests() do
      stub_api(fn conn ->
        assert conn.request_path == expected_path
        json_response(conn, 200, %{"ok" => true})
      end)

      # Token.delete/3 answers :ok, the others {:ok, body}.
      result = call.(@id)
      assert result == :ok or match?({:ok, _}, result), "no request to #{expected_path}"
    end
  end

  test "an integer id is sent as its digits" do
    stub_api(fn conn ->
      assert conn.request_path == "/v2/checkout/sessions/42"
      json_response(conn, 200, %{"ok" => true})
    end)

    assert {:ok, _} = Checkout.get_session(42)
  end

  test "Payment.get/2 encodes the id in its stream's path" do
    stub_stream()

    assert {:ok, %{"status" => "NEW"}} = Payment.get(@id)
    assert_requested("/poslink/v3/payment-requests/#{@encoded}")
  end

  test "Payment.subscribe/2 encodes the id, and sends messages with the id as given" do
    stub_stream()

    {:ok, _task} = Payment.subscribe(@id)

    assert_requested("/poslink/v3/payment-requests/#{@encoded}")
    assert_receive {:poslink_payment, @id, "full", %{"status" => "NEW"}}, 500
  end

  test "Receipt.subscribe_status/2 encodes the id, and sends messages with the id as given" do
    stub_stream()

    {:ok, _task} = POSLinkReceipt.subscribe_status(@id)

    assert_requested("/poslink/v1/receipt-requests/#{@encoded}/status")
    assert_receive {:poslink_receipt, @id, "full", %{"status" => "NEW"}}, 500
  end

  test "an id that cannot be a path segment raises before any request" do
    stub_api(fn _conn -> flunk("no request should be sent") end)

    calls = Enum.map(requests(), &elem(&1, 1)) ++ streams()

    for call <- calls, id <- [nil, "", ".", "..", %{"id" => "x"}] do
      # A stream function raising here, not in its task, is the point: the
      # mistake shows where it was made.
      assert_raise ArgumentError, ~r/path segment/, fn -> call.(id) end
    end
  end
end
