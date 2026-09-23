defmodule Teya.SSE do
  @moduledoc """
  SSE streaming helper for Teya POSLink streaming endpoints.

  Wraps `Req` with the `req_server_sent_events` plugin to decode the byte
  stream into events. JSON-decodes the `data` field of each event and forwards
  decoded maps to the caller process as `{ok_tag, id, event_type, data}`
  messages. Non-200 responses and transport errors are forwarded as
  `{error_tag, id, reason}`.

  An error response is not an event stream, so its body is collected as raw
  bytes and left to Req to decode. That keeps the `code` and `message` the API
  sent in the resulting `%Teya.Error{}`.
  """

  alias ReqServerSentEvents.Frame
  alias Teya.Error

  @max_error_body_bytes 65_536

  @doc false
  def max_error_body_bytes, do: @max_error_body_bytes

  @doc false
  def stream(url, token, id, ok_tag, error_tag, pid, req_opts \\ []) do
    timeout_ms = Application.get_env(:teya, :sse_stream_timeout_ms, 60_000)

    handler = fn {:sse_event, %Frame{} = frame}, {req, resp} ->
      if resp.status == 200, do: forward_frame(frame, id, ok_tag, pid)
      {:cont, {req, resp}}
    end

    req =
      req_opts
      |> Keyword.merge(
        url: url,
        auth: {:bearer, token},
        into: handler,
        # An error body that ran past the cap is cut short, and Req's decoder
        # answers broken JSON with an exception in place of the response,
        # taking the status with it. Decode it here instead.
        decode_body: false,
        receive_timeout: timeout_ms
      )
      |> Req.new()
      |> ReqServerSentEvents.attach()
      |> collect_error_body()

    case Req.get(req) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, resp} ->
        send(pid, {error_tag, id, resp |> decode_body() |> Error.from_response()})

      {:error, reason} ->
        send(pid, {error_tag, id, reason})
    end
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
    body = take_error_body(resp.body, chunk)
    resp = %{resp | body: body}

    # Nothing more will be kept, so stop reading rather than pulling a whole
    # error page off the wire to throw it away.
    if byte_size(body) >= @max_error_body_bytes,
      do: {:halt, {req, resp}},
      else: {:cont, {req, resp}}
  end

  @doc false
  # An error body is not streamed, so it could be any size — a gateway error
  # page, say. The budget is generous because a cut body is no longer valid
  # JSON, and a JSON error loses its code and description when it cannot be
  # decoded; an API error listing many invalid parameters still fits well
  # inside it. A whole response often arrives as one chunk, so the chunk
  # itself is cut to what is left of the budget rather than copied first and
  # cut later.
  def take_error_body(body, chunk) do
    body = body || ""
    budget = @max_error_body_bytes - byte_size(body)

    cond do
      budget <= 0 -> body
      byte_size(chunk) <= budget -> body <> chunk
      true -> body <> binary_part(chunk, 0, budget)
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

  defp forward_frame(%Frame{data: nil}, _id, _ok_tag, _pid), do: :ok

  defp forward_frame(%Frame{data: data, event: event}, id, ok_tag, pid) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> send(pid, {ok_tag, id, event, decoded})
      _ -> :ok
    end
  end
end
