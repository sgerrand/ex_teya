defmodule Teya.SSE do
  @moduledoc """
  SSE streaming helper for Teya POSLink streaming endpoints.

  Wraps `Req` with the `req_server_sent_events` plugin to decode the byte
  stream into events. JSON-decodes the `data` field of each event and forwards
  decoded maps to the caller process as `{ok_tag, id, event_type, data}`
  messages. Non-200 responses and transport errors are forwarded as
  `{error_tag, id, reason}`.
  """

  alias ReqServerSentEvents.Frame
  alias Teya.Error

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
        receive_timeout: timeout_ms
      )
      |> Req.new()
      |> ReqServerSentEvents.attach()

    case Req.get(req) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, resp} ->
        send(pid, {error_tag, id, Error.from_response(resp)})

      {:error, reason} ->
        send(pid, {error_tag, id, reason})
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
