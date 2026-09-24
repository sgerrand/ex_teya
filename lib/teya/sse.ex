defmodule Teya.SSE do
  @moduledoc """
  SSE streaming helper for Teya POSLink streaming endpoints.

  Wraps `Req` with the `req_server_sent_events` plugin to decode the byte
  stream into events, and JSON-decodes the `data` field of each one. There are
  two ways to read a stream:

  - `stream/6` follows it to the end and sends each event to a process as
    `{ok_tag, id, event_type, data}`. Non-200 responses and transport errors
    are sent as `{error_tag, id, reason}`.
  - `first/4` sends nothing. It reads up to the first event with a given name,
    closes the stream there, and returns that event's data.

  Requests use `:sse_req_options` from the application config, falling back
  to `:req_options`.

  An error response is not an event stream, so its body is collected as raw
  bytes and decoded here, which keeps the `code` and `message` the API sent in
  the resulting `%Teya.Error{}`.

  Only the first `:sse_max_error_body_bytes` of that body are kept (64 KB by
  default), so a large error page cannot fill memory. A JSON body past that
  size is cut and can no longer be decoded: the `%Teya.Error{}` then carries
  the status and the raw text, but no `code`.
  """

  alias ReqServerSentEvents.Frame
  alias Teya.Error

  @default_max_error_body_bytes 65_536

  @doc false
  def stream(url, token, id, ok_tag, error_tag, pid) do
    # Only a 200 response reaches this handler: collect_error_body/1 keeps
    # every other status's bytes for the error instead.
    handler = fn {:sse_event, %Frame{} = frame}, {req, resp} ->
      with {event, data} <- decode_frame(frame), do: send(pid, {ok_tag, id, event, data})
      {:cont, {req, resp}}
    end

    case url |> request(token, handler) |> Req.get() do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, resp} ->
        send(pid, {error_tag, id, resp |> decode_body() |> Error.from_response()})

      {:error, reason} ->
        send(pid, {error_tag, id, reason})
    end
  end

  @doc false
  # Reads the stream until the first event named `event_type`, closes it
  # there, and returns that event's data. Nothing is sent to any process, so
  # no mailbox ever sees the stream.
  #
  # `owner` is the process waiting for the answer. Once it has died, the read
  # stops at the next event rather than holding a connection open for nobody,
  # which could otherwise last as long as the payment if no such event came.
  #
  # Returns `{:ok, data}`, `:none` when the stream closed without such an
  # event, or `{:error, reason}`.
  def first(url, token, event_type, owner) do
    handler = fn {:sse_event, %Frame{} = frame}, acc ->
      take_first(decode_frame(frame), event_type, owner, acc)
    end

    case url |> request(token, handler) |> Req.get() do
      {:ok, %{status: 200} = resp} ->
        case Req.Response.get_private(resp, :sse_first) do
          nil -> :none
          data -> {:ok, data}
        end

      {:ok, resp} ->
        {:error, resp |> decode_body() |> Error.from_response()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp take_first({event_type, data}, event_type, _owner, {req, resp}) do
    {:halt, {req, Req.Response.put_private(resp, :sse_first, data)}}
  end

  defp take_first(_other, _event_type, owner, {req, resp}) do
    if Process.alive?(owner), do: {:cont, {req, resp}}, else: {:halt, {req, resp}}
  end

  defp request(url, token, handler) do
    Application.get_env(:teya, :sse_req_options, Application.get_env(:teya, :req_options, []))
    |> Keyword.merge(
      url: url,
      auth: {:bearer, token},
      into: handler,
      # An error body that ran past the cap is cut short, and Req's decoder
      # answers broken JSON with an exception in place of the response,
      # taking the status with it. Decode it here instead.
      decode_body: false,
      receive_timeout: Application.get_env(:teya, :sse_stream_timeout_ms, 60_000)
    )
    |> Req.new()
    |> ReqServerSentEvents.attach()
    |> collect_error_body()
  end

  # The SSE plugin decodes every chunk as event-stream bytes, which drops the
  # body of an error response: it has no frame delimiter, so it sits in the
  # plugin's buffer forever. Wrap the plugin's collector and keep the raw
  # bytes for every status this module does not stream, which is anything
  # other than 200.
  defp collect_error_body(%Req.Request{into: sse_into} = req) do
    collector = fn {:data, chunk}, {req, resp} ->
      if resp.status == 200,
        do: sse_into.({:data, chunk}, {req, resp}),
        else: keep_error_chunk(chunk, {req, resp})
    end

    %{req | into: collector}
  end

  defp keep_error_chunk(chunk, {req, resp}) do
    {body, cut?} = take_error_body(resp.body, chunk, max_error_body_bytes())
    resp = %{resp | body: body}

    # Once a chunk has been cut, nothing more will be kept, so stop reading
    # rather than pulling a whole error page off the wire to throw it away.
    # The kept body can end up shorter than the cap, so its size cannot be
    # what decides this.
    if cut?,
      do: {:halt, {req, resp}},
      else: {:cont, {req, resp}}
  end

  defp max_error_body_bytes do
    case Application.get_env(:teya, :sse_max_error_body_bytes, @default_max_error_body_bytes) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _ -> @default_max_error_body_bytes
    end
  end

  # An error body is not streamed, so it could be any size — a gateway error
  # page, say. The default budget is generous because a cut body is no longer
  # valid JSON, and a JSON error loses its code and description when it cannot
  # be decoded; an API error listing many invalid parameters still fits well
  # inside it. A whole response often arrives as one chunk, so the chunk
  # itself is cut to what is left of the budget rather than copied first and
  # cut later.
  defp take_error_body(body, chunk, limit) do
    body = body || ""
    budget = max(limit - byte_size(body), 0)

    if byte_size(chunk) <= budget do
      {body <> chunk, false}
    else
      # Trim what the body becomes, not the piece taken from this chunk: a
      # character can start in one chunk and finish in the next, so a piece
      # can read as broken text on its own while the whole body is fine, and
      # the other way round.
      {whole_characters(body <> binary_part(chunk, 0, budget)), true}
    end
  end

  # Cutting at a byte boundary can split a character in two, leaving text that
  # no longer prints as text. A character is at most four bytes, so drop up to
  # three trailing bytes to end on a whole one. Anything still not text was
  # never text — a compressed or mis-encoded error page — and is handed back
  # whole rather than walked back byte by byte to the first bad one.
  defp whole_characters(text), do: whole_characters(text, text, 3)

  defp whole_characters(original, _trimmed, 0), do: original

  defp whole_characters(original, trimmed, attempts) do
    if String.valid?(trimmed) do
      trimmed
    else
      whole_characters(original, binary_part(trimmed, 0, byte_size(trimmed) - 1), attempts - 1)
    end
  end

  defp decode_body(resp) do
    with body when is_binary(body) <- resp.body,
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      %{resp | body: decoded}
    else
      _ -> resp
    end
  end

  # A frame with no data, such as a keepalive, or data that is not a JSON
  # object, carries nothing to pass on.
  defp decode_frame(%Frame{data: nil}), do: nil

  defp decode_frame(%Frame{data: data, event: event}) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> {event, decoded}
      _ -> nil
    end
  end
end
