defmodule Teya.SSE do
  @moduledoc """
  SSE streaming helper for Teya POSLink streaming endpoints.

  Wraps `Req` with the `req_server_sent_events` plugin to decode the byte
  stream into events, and JSON-decodes the `data` field of each one. There are
  two ways to read a stream:

  - `subscribe/6` starts a task that follows it to the end and sends each
    event to a process as `{ok_tag, ref, id, event_type, data}`, where `ref`
    is the `ref` of the `%Task{}` it returns. Non-200 responses, transport
    errors and crashes are sent as `{error_tag, ref, id, %Teya.Error{}}`.
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
  the status, but no `code` and none of the body.
  """

  alias ReqServerSentEvents.Frame
  alias Teya.{Client, Error, HTTP}

  @default_max_error_body_bytes 65_536

  # Payment and receipt events are a few hundred bytes. A megabyte is far past
  # anything real while still bounding what a runaway body can hold.
  @max_frame_bytes 1_048_576

  @doc false
  # Starts a subscribe task for `path`, text or a template as Client.path/1
  # takes, and returns
  # `{:ok, task}`. The task sends it to the host of the set whose token it
  # carries. Every message
  # it sends `pid` carries `task.ref`, so two streams for the same id can be
  # told apart:
  #
  #     {ok_tag, ref, id, event, data}
  #     {error_tag, ref, id, %Teya.Error{}}
  #
  # A task cannot see its own ref, which belongs to the caller's monitor, so
  # the caller sends it once the task has started, and the task waits for it
  # before it opens the stream.
  def subscribe(path, set, id, pid, ok_tag, error_tag) do
    # Built here, in the caller, so a bad id raises where the mistake was
    # made. The task builds it again, with its host, in session_url/2.
    Client.path(path)
    caller = self()

    task =
      Task.Supervisor.async_nolink(Teya.TaskSupervisor, fn ->
        subscription(path, set, id, pid, {ok_tag, error_tag}, caller)
      end)

    send(task.pid, {:teya_subscription_ref, task.ref})
    {:ok, task}
  end

  @doc false
  # The subscribe task: waits for its ref, then streams. The caller sends
  # the ref as soon as subscribe/6 has the task, so it comes unless the
  # caller dies first, and the monitor tells which. There is no timeout: a
  # caller that is only slow still sends the ref it returns, and streaming
  # without it would send messages that ref can never match.
  #
  # If the caller dies first, nobody can hold the ref, since subscribe/6
  # never returned it, so the task streams anyway with nil as the ref: a
  # recipient other than the caller that matches any ref still hears from
  # the stream, as an unlinked task would carry on for it before refs were
  # added.
  def subscription(path, set, id, pid, tags, caller) do
    monitor = Process.monitor(caller)

    ref =
      receive do
        {:teya_subscription_ref, ref} -> ref
        {:DOWN, ^monitor, :process, _pid, _reason} -> nil
      end

    Process.demonitor(monitor, [:flush])
    {_ok_tag, error_tag} = tags
    guard(fn -> run_subscription(path, set, {ref, id}, pid, tags) end, pid, error_tag, {ref, id})
  end

  # Returns :ok however it ends. The task's result goes to the caller as
  # its reply, so an error returned here would reach the caller a second
  # time, in another shape, and reach it even when it is not `pid`.
  # The host comes with the token, in one answer from the set's auth
  # process, and is joined to the path only then.
  defp run_subscription(path, set, {ref, id}, pid, {ok_tag, error_tag}) do
    case Client.session_url(path, set) do
      {:ok, token, url} -> stream(url, token, {ref, id}, ok_tag, error_tag, pid)
      {:error, error} -> send(pid, {error_tag, ref, id, error})
    end

    :ok
  end

  defp stream(url, token, {ref, id}, ok_tag, error_tag, pid) do
    # Only a 200 response reaches this handler: collect_error_body/1 keeps
    # every other status's bytes for the error instead.
    handler = fn {:sse_event, %Frame{} = frame}, {req, resp} ->
      with {event, data} <- decode_frame(frame), do: send(pid, {ok_tag, ref, id, event, data})
      {:cont, {req, resp}}
    end

    case url |> request(token, handler) |> run() do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, resp} ->
        send(pid, {error_tag, ref, id, error_from_response(resp)})

      {:error, reason} ->
        send(pid, {error_tag, ref, id, Error.from_reason(reason, "the stream failed")})
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
  # event, or `{:error, %Teya.Error{}}`.
  def first(path, set, event_type, owner) do
    with {:ok, token, url} <- Client.session_url(path, set),
         do: read_first(url, token, event_type, owner)
  end

  defp read_first(url, token, event_type, owner) do
    handler = fn {:sse_event, %Frame{} = frame}, acc ->
      take_first(frame, event_type, owner, acc)
    end

    case url |> request(token, handler) |> run() do
      {:ok, %{status: 200} = resp} ->
        case Req.Response.get_private(resp, :sse_first) do
          nil -> :none
          data -> {:ok, data}
        end

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, Error.from_reason(reason, "the stream failed")}
    end
  end

  # Only a frame with the name asked for is decoded; the rest are passed over
  # without the cost of reading their JSON.
  defp take_first(%Frame{event: event_type} = frame, event_type, owner, {req, resp}) do
    case decode_frame(frame) do
      {_event, data} -> {:halt, {req, Req.Response.put_private(resp, :sse_first, data)}}
      nil -> keep_reading?(owner, {req, resp})
    end
  end

  defp take_first(_frame, _event_type, owner, acc), do: keep_reading?(owner, acc)

  defp keep_reading?(owner, {req, resp}) do
    if Process.alive?(owner), do: {:cont, {req, resp}}, else: {:halt, {req, resp}}
  end

  defp request(url, token, handler) do
    configured = HTTP.options(:sse_req_options)

    # Req retries a failed GET by default, which for a stream means opening it
    # again without a word: the reader never learns the connection dropped,
    # and the new stream replays its snapshot. Readers are told of a dropped
    # stream and reconnect themselves, so retrying is off unless configured.
    # The user agent is Req's own option, which gives way to one configured
    # as an option or a header.
    [retry: false, user_agent: HTTP.user_agent()]
    |> Keyword.merge(configured)
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
    # The library sets Idempotency-Key itself, on API calls that need one. A
    # key in config that the options fall back to means nothing on a stream.
    |> Req.Request.delete_header("idempotency-key")
    # A 200 body with no frame delimiter — a proxy's HTML page, say — would
    # otherwise sit in the plugin's buffer and grow until the body ends.
    |> ReqServerSentEvents.attach(max_frame_size: @max_frame_bytes)
    |> collect_error_body()
  end

  # The plugin raises when a frame outgrows its buffer. Raised inside a stream
  # task, that would end the task without telling the reader anything, so it
  # is turned into an error like any other.
  defp run(req) do
    Req.get(req)
  rescue
    error in ReqServerSentEvents.FrameTooLargeError -> {:error, error}
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

  defp error_from_response(resp) do
    case HTTP.decode_json(resp, unlabelled: true) do
      {:ok, resp} -> Error.from_response(resp)
      {:unreadable, resp} -> Error.unreadable(resp)
    end
  end

  @doc false
  # Runs a stream task's work, turning any crash into an error there, in the
  # task. Left to crash, the task would log a crash report, and the exception,
  # the value that failed to match or the stacktrace could hold the bearer
  # token or what the stream sent. Only the crash's kind and, for a raised
  # error, the exception's name are kept.
  def guard(fun) do
    fun.()
  catch
    kind, reason -> {:error, crashed(kind, reason)}
  end

  @doc false
  # The same for a subscribe task, whose crash is sent to `pid` as the
  # stream's error message.
  def guard(fun, pid, error_tag, {ref, id}) do
    fun.()
  catch
    kind, reason ->
      send(pid, {error_tag, ref, id, crashed(kind, reason)})
      :ok
  end

  defp crashed(kind, reason),
    do: Error.from_reason({:crashed, crash_name(kind, reason)}, "the stream task crashed")

  defp crash_name(:error, reason), do: Exception.normalize(:error, reason, []).__struct__
  defp crash_name(kind, _reason), do: kind

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
