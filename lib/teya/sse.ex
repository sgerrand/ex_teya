defmodule Teya.SSE do
  @moduledoc """
  SSE (Server-Sent Events) frame parser for consuming Teya POSLink streaming endpoints.

  Parses raw bytes from a streaming HTTP response into event maps. Designed for
  use with `Req`'s `into: :self` streaming mode, where chunks arrive as
  `{ref, {:data, binary}}` messages.

  ## Usage

      defp receive_loop(ref, buffer) do
        receive do
          {^ref, {:data, chunk}} ->
            {events, rest} = Teya.SSE.parse(buffer <> chunk)
            Enum.each(events, &handle_event/1)
            receive_loop(ref, rest)

          {^ref, :done} ->
            :ok
        end
      end

  ## Event format

  Each parsed event is a map with string keys. Only fields present in the SSE
  frame are included.

      %{
        "event" => "full",             # event type (if present)
        "data"  => "{\"status\":\"NEW\"}",  # raw data string (multi-line joined with \\n)
        "id"    => "event-id",         # last event ID (if present)
        "retry" => 5000                # reconnect delay in ms (if present)
      }

  Events without a `data:` line (e.g. keepalive comment-only frames) are
  discarded and never appear in the output list.
  """

  alias Teya.Error

  @type event :: %{String.t() => String.t() | non_neg_integer()}

  @doc """
  Parses complete SSE events from a binary buffer.

  Returns `{events, remaining}` where `events` is the list of parsed event maps
  and `remaining` is any trailing bytes that do not yet form a complete event,
  to be prepended to the next incoming chunk.

  ## Examples

      iex> Teya.SSE.parse("event: full\\ndata: {}")
      {[], "event: full\\ndata: {}"}

      iex> Teya.SSE.parse("event: full\\ndata: {}\\n\\n")
      {[%{"event" => "full", "data" => "{}"}], ""}

  """
  @spec parse(binary()) :: {[event()], binary()}
  def parse(buffer) when is_binary(buffer) do
    parts = :binary.split(buffer, ["\r\n\r\n", "\n\n"], [:global])

    case parts do
      [remaining] ->
        {[], remaining}

      _ ->
        {complete, [remaining]} = Enum.split(parts, -1)

        events =
          complete
          |> Enum.map(&parse_frame/1)
          |> Enum.reject(&is_nil/1)

        {events, remaining}
    end
  end

  @doc false
  def stream(url, token, id, ok_tag, error_tag, pid, req_opts \\ []) do
    case Req.get(url, [auth: {:bearer, token}, into: :self] ++ req_opts) do
      {:ok, %{status: 200, body: %Req.Response.Async{ref: ref}}} ->
        stream_loop(ref, "", id, ok_tag, error_tag, pid)

      {:ok, resp} ->
        send(pid, {error_tag, id, Error.from_response(resp)})

      {:error, reason} ->
        send(pid, {error_tag, id, reason})
    end
  end

  defp stream_loop(ref, buffer, id, ok_tag, error_tag, pid) do
    timeout_ms = Application.get_env(:teya, :sse_stream_timeout_ms, 60_000)

    receive do
      {^ref, {:data, chunk}} ->
        {events, rest} = parse(buffer <> chunk)

        Enum.each(events, fn event ->
          event_type = Map.get(event, "event")

          case Jason.decode(Map.get(event, "data", "null")) do
            {:ok, data} when is_map(data) -> send(pid, {ok_tag, id, event_type, data})
            _ -> :ok
          end
        end)

        stream_loop(ref, rest, id, ok_tag, error_tag, pid)

      {^ref, :done} ->
        :ok

      {^ref, {:error, reason}} ->
        send(pid, {error_tag, id, reason})
    after
      timeout_ms -> send(pid, {error_tag, id, :stream_timeout})
    end
  end

  defp parse_frame(""), do: nil

  defp parse_frame(frame) do
    event =
      frame
      |> String.split(~r/\r?\n/)
      |> Enum.reduce(%{}, &apply_line/2)

    if Map.has_key?(event, "data"), do: event, else: nil
  end

  # SSE spec: lines starting with ":" are comments — ignored.
  defp apply_line(":" <> _comment, acc), do: acc
  defp apply_line("", acc), do: acc

  defp apply_line(line, acc) do
    case String.split(line, ":", parts: 2) do
      [field, raw_value] ->
        value = String.trim_leading(raw_value, " ")
        apply_field(String.trim(field), value, acc)

      _ ->
        acc
    end
  end

  # Multi-line data is joined with "\n" per the SSE spec.
  defp apply_field("data", value, acc) do
    Map.update(acc, "data", value, &(&1 <> "\n" <> value))
  end

  defp apply_field("event", value, acc), do: Map.put(acc, "event", value)
  defp apply_field("id", value, acc), do: Map.put(acc, "id", value)

  defp apply_field("retry", value, acc) do
    case Integer.parse(value) do
      {ms, ""} -> Map.put(acc, "retry", ms)
      _ -> acc
    end
  end

  defp apply_field(_unknown, _value, acc), do: acc
end
