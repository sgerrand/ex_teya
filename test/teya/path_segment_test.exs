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

  describe "Client.path/1" do
    alias Teya.Client

    test "takes a plain path as it is, and encodes each value in a template" do
      assert Client.path("/v2/checkout/sessions") == "/v2/checkout/sessions"

      assert Client.path(
               {"/poslink/v1/stores/:store_id/configs/:key", store_id: "s 1", key: "A/B"}
             ) ==
               "/poslink/v1/stores/s%201/configs/A%2FB"
    end

    test "raises for a mistake in the calling code" do
      cases = [
        {{"/v1/tokens/:id", []}, ~r/no value given for :id/},
        {{"/v1/tokens/:id", id: "t", store_id: "s"}, ~r/no placeholder for \["store_id"\]/},
        {"/v1/tokens/tok-1?x=1", ~r/not a plain path/},
        {"/v1/tokens/" <> "Tok_1", ~r/not a plain path/},
        {{"/v1/Tokens/:id", id: "t"}, ~r/not a plain path/}
      ]

      for {path, message} <- cases do
        assert_raise ArgumentError, message, fn -> Client.path(path) end
      end
    end
  end

  # Encoding in Client.path/1 only helps if every path goes through it. A
  # value interpolated into or joined onto a path string skips it, so no
  # module may build a path that way. The check reads the parsed code, not
  # the text, so an expression split across lines is caught all the same.
  test "no module builds a request path by interpolation or concatenation" do
    offenders =
      for file <- Path.wildcard("lib/**/*.ex"),
          node <- file |> File.read!() |> Code.string_to_quoted!() |> nodes(),
          built_path?(node),
          do: "#{file}:#{node |> elem(1) |> Keyword.get(:line)}"

    assert offenders == []
  end

  test "the path check catches a path joined across lines" do
    code = """
    Client.request(
      :get,
      "/v1/tokens/" <>
        token_id,
      opts
    )
    Client.request(:get, "/v1/tokens/\#{
      token_id
    }", opts)
    """

    assert code |> Code.string_to_quoted!() |> nodes() |> Enum.count(&built_path?/1) == 2
  end

  defp nodes(ast) do
    {_ast, found} = Macro.prewalk(ast, [], fn node, found -> {node, [node | found]} end)
    found
  end

  # "/..." <> value, or value <> "/...": a literal path with a value joined on.
  defp built_path?({:<>, _meta, [left, right]}),
    do:
      (path_literal?(left) and not is_binary(right)) or
        (path_literal?(right) and not is_binary(left))

  # "/...#{value}...": an interpolated string that starts as a path.
  defp built_path?({:<<>>, _meta, [first | _rest] = parts}),
    do: path_literal?(first) and Enum.any?(parts, &(not is_binary(&1)))

  defp built_path?(_node), do: false

  defp path_literal?(value), do: is_binary(value) and String.starts_with?(value, "/")
end
