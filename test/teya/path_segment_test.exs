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

    {:ok, %Task{ref: ref}} = Payment.subscribe(@id)

    assert_requested("/poslink/v3/payment-requests/#{@encoded}")
    assert_receive {:poslink_payment, ^ref, @id, "full", %{"status" => "NEW"}}, 500
  end

  test "Receipt.subscribe_status/2 encodes the id, and sends messages with the id as given" do
    stub_stream()

    {:ok, %Task{ref: ref}} = POSLinkReceipt.subscribe_status(@id)

    assert_requested("/poslink/v1/receipt-requests/#{@encoded}/status")
    assert_receive {:poslink_receipt, ^ref, @id, "full", %{"status" => "NEW"}}, 500
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
        {{"/v1/Tokens/:id", id: "t"}, ~r/not a plain path/},
        {{"/v1/tokens/:id", %{id: "t"}}, ~r/must be a keyword list/},
        {{"/v1/tokens/:id", ["t"]}, ~r/must be a keyword list/},
        {{"/v1/tokens/:id", [{"id", "t"}]}, ~r/must be a keyword list/},
        {{"/v1/tokens/:id", id: "a", id: "b"}, ~r/given twice/},
        {:not_a_path, ~r/a path is text or \{template, values\}/}
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
  @lib Path.expand("../../lib", __DIR__)

  test "no module builds a request path by interpolation or concatenation" do
    files = Path.wildcard(Path.join(@lib, "**/*.ex"))
    # With no files found the check would pass having looked at nothing.
    assert length(files) > 20

    offenders =
      for file <- files,
          node <- file |> File.read!() |> Code.string_to_quoted!() |> nodes(),
          built_path?(node) or (Path.basename(file) != "client.ex" and joined_path?(node)),
          do: "#{Path.relative_to(file, @lib)}:#{node |> elem(1) |> Keyword.get(:line)}"

    assert offenders == []
  end

  test "the path check catches each way of building a path by hand" do
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
    url = "\#{HTTP.base_url()}/poslink/v1/receipt-requests/\#{receipt_id}/status"
    Client.request(:get, "/v1/Tokens_x/" <> id, opts)
    Client.request(:get, Path.join(["/poslink/v1/stores", store_id, "terminals"]), opts)
    Client.request(:get, Enum.join(["", "v1", "tokens", id], "/"), opts)
    Client.request(:get, "\#{prefix}/tokens/\#{id}", opts)
    Client.request(:get, "\#{prefix}tokens/\#{id}", opts)
    user_agent = "teya-elixir/\#{version}"
    """

    ast = Code.string_to_quoted!(code)
    assert Enum.count(nodes(ast), &(built_path?(&1) or joined_path?(&1))) == 8
  end

  test "the path check leaves a pattern that matches a path's start alone" do
    ast = Code.string_to_quoted!(~S[defp api("/poslink/" <> _rest), do: :poslink])
    refute Enum.any?(nodes(ast), &(built_path?(&1) or joined_path?(&1)))
  end

  defp nodes(ast) do
    {_ast, found} = Macro.prewalk(ast, [], fn node, found -> {node, [node | found]} end)
    found
  end

  # "/..." <> value, or value <> "/...": a literal path with a value joined
  # on. A pattern such as "/poslink/" <> _rest matches a path, and builds
  # none, so an underscored name on the other side is left alone.
  defp built_path?({:<>, _meta, [left, right]}),
    do:
      (path_literal?(left) and value?(right)) or
        (path_literal?(right) and value?(left))

  # "...#{value}..." with a path part before a value: an interpolated path.
  # A part is a path part if it starts with "/", such as "/v1/tokens/", or
  # if it holds a "/" and follows a value, as "tokens/" does in
  # "#{prefix}tokens/#{id}", so a string that starts with a value such as a
  # prefix or the base URL is caught too. A "/" in a string's own leading
  # text, as in "teya-elixir/#{version}", starts no path.
  defp built_path?({:<<>>, _meta, parts}) do
    parts
    |> Enum.with_index()
    |> Enum.drop_while(fn {part, index} -> not path_part?(part, index) end)
    |> Enum.any?(fn {part, _index} -> not is_binary(part) end)
  end

  defp built_path?(_node), do: false

  # Path.join/1,2 or Enum.join/2 with "/": a path put together from parts.
  # Client.path/1 is the one place allowed to do that.
  defp joined_path?({{:., _, [{:__aliases__, _, [:Path]}, :join]}, _meta, _args}), do: true

  defp joined_path?({{:., _, [{:__aliases__, _, [:Enum]}, :join]}, _meta, [_list, "/"]}),
    do: true

  defp joined_path?(_node), do: false

  defp path_literal?(value), do: is_binary(value) and String.starts_with?(value, "/")

  defp path_part?(part, index),
    do: path_literal?(part) or (index > 0 and is_binary(part) and String.contains?(part, "/"))

  defp value?(value) when is_binary(value), do: false

  defp value?({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: not String.starts_with?(Atom.to_string(name), "_")

  defp value?(_other), do: true
end
