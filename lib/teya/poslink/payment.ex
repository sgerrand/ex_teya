defmodule Teya.POSLink.Payment do
  @moduledoc """
  POSLink payment requests — initiate and manage card-present payments at terminals.

  A payment request instructs a specific terminal to collect a card payment.
  Status transitions: `NEW` → `IN_PROGRESS` → `SUCCESSFUL` | `FAILED` | `CANCELLED`.

  Use `create/2` to start a payment and `subscribe/2` to receive real-time
  status updates via the terminal's SSE stream.

  `create/2`, `list/1` and `cancel/2` need the `payment_requests` scope.
  `get/2`, `subscribe/2` and `receipt_text/2` need `payment_requests/id`. The
  deprecated `default_access` also works for all of them.

  ## Task lifecycle

  `subscribe/2` returns `{:ok, %Task{}}` immediately. The task runs under
  `Teya.TaskSupervisor` with `async_nolink`, meaning:

  - The task is **not linked** to the caller — a task crash does not take down
    the calling process.
  - The supervisor does **not restart** the task if it exits.
  - If the **caller process dies**, the task continues running until the SSE
    stream ends or errors, then exits normally.
  - If the **SSE stream disconnects** mid-payment (network error, server
    restart), the task sends `{:poslink_payment_error, ref, id, reason}` and exits.
    There is no automatic reconnection. To recover, call `get/2` to fetch the
    current status, or call `subscribe/2` again to open a fresh stream. A new
    stream always starts with a full snapshot of the payment request.
  """

  alias Teya.{Auth, Client, Error, SSE}

  @doc """
  Creates a payment request at a terminal.

  Returns `{:ok, response}` containing the `payment_request_id` and initial
  `status` (`"NEW"`). Use the returned `payment_request_id` with `subscribe/2`
  to stream status updates as the cardholder interacts with the terminal.

  ## Required params

  - `store_id` — UUID of the store
  - `terminal_id` — UUID of the target terminal
  - `requested_amount` — `%{"amount" => 1000, "currency" => "GBP"}` (amount
    in minor units); optionally include `"tip"` for tip-enabled terminals
  - `transaction_type` — `"SALE"` or `"REFUND"`
  - `merchant_reference` — caller-supplied reference (max 60 chars)

  ## Optional params

  - `epos_instance_id` — identifier of the ePOS instance making the request
  - `basket_transaction_id` — identifier of the basket in the ePOS
  - `tab_id` — Pay at Table tab to settle; requires `payment_type`
  - `payment_type` — `"FULL"` or `"SPLIT"`
  - `payment_method` — `"CARD"` or `"CASH"`

  ## Options

  - `:idempotency_key` — override the auto-generated idempotency key

  ## Examples

      params = %{
        "store_id"           => store_id,
        "terminal_id"        => terminal_id,
        "requested_amount"   => %{"amount" => 1000, "currency" => "GBP"},
        "transaction_type"   => "SALE",
        "merchant_reference" => "order-1234"
      }

      {:ok, %{"payment_request_id" => id}} = Teya.POSLink.Payment.create(params)
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.idempotent_post("/poslink/v3/payment-requests", Keyword.put(opts, :body, params))
  end

  @doc """
  Cancels an in-progress payment request.

  Sends a `PATCH` to set `status` to `"CANCELLED"`. The terminal will abort
  the current payment interaction. The request is idempotent: cancelling an
  already-terminal payment (e.g. `SUCCESSFUL`) returns an error.

  ## Parameters

  - `payment_request_id` — UUID returned from `create/2`

  ## Options

  - `:idempotency_key` — override the auto-generated idempotency key

  ## Examples

      {:ok, %{"status" => "CANCELLING"}} = Teya.POSLink.Payment.cancel(payment_request_id)
  """
  @spec cancel(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def cancel(payment_request_id, opts \\ []) do
    body = %{"status" => "CANCELLED"}

    Client.request(
      :patch,
      {"/poslink/v2/payment-requests/:id", id: payment_request_id},
      Keyword.put(opts, :body, body)
    )
  end

  @doc """
  Fetches the current state of a single payment request or refund by its ID.

  The POSLink API has no plain JSON endpoint for a single payment request.
  This function opens the status stream in a task of its own, reads it up to
  the first full snapshot, and closes it there. The stream's events never
  reach the calling process, so a `subscribe/2` stream it already has open for
  the same payment is left alone.

  If the calling process dies while waiting, the task stops reading at the
  next event the stream sends.

  Useful as a fallback when an SSE stream from `subscribe/2` disconnects before
  the payment reaches a terminal state — check the current status, then
  re-subscribe if still in progress.

  ## Parameters

  - `payment_request_id` — UUID returned from `create/2`

  ## Options

  - `:timeout` — milliseconds to wait for the snapshot (default `30_000`).
    `:infinity` waits for as long as the stream stays open without one, which
    for a stream that sends only partial updates can be the life of the
    payment
  - `:credentials` — the named set of credentials to use, as for every call

  ## Errors

  Every error is a `%Teya.Error{}`. When the API or the token endpoint
  refused the request, it has a `status` and `code`; a token failure carries
  an OAuth code such as `"invalid_client"`. Otherwise `status` is `nil` and
  `reason` says what happened:

  - `:timeout` — no snapshot arrived before `:timeout` passed
  - `:no_snapshot` — the stream closed without sending a full snapshot, for
    example after only partial updates; subscribe to it instead
  - `{:crashed, name}` — the task reading the stream crashed; `name` is the
    exception's name, such as `RuntimeError`, or `:exit` or `:throw`. Only
    the name is kept, since the rest could hold the bearer token
  - `{:exit, name}` — the task was stopped from outside, such as `:killed`
  - an exception, such as `%Req.TransportError{}` — a network error

  Raises `ArgumentError`, before opening any stream, for an id that cannot be
  part of a path: `nil`, empty, `"."`, `".."`, or anything but text or an
  integer, or for `:credentials` that are not configured. That is a mistake
  in the calling code, not something the API said.

  ## Examples

      {:ok, payment} = Teya.POSLink.Payment.get(payment_request_id)
      payment["status"]  # "NEW" | "IN_PROGRESS" | "SUCCESSFUL" | "FAILED" | "CANCELLING" | "CANCELLED"
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def get(payment_request_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    caller = self()
    set = Auth.set_for(opts, :poslink)
    url = stream_url(payment_request_id, set)

    task =
      Task.Supervisor.async_nolink(Teya.TaskSupervisor, fn ->
        SSE.guard(fn -> fetch_snapshot(url, set, caller) end)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      # Only when the task was killed from outside: it catches its own crashes.
      {:exit, reason} ->
        {:error,
         Error.from_reason({:exit, exit_name(reason)}, "the task reading the stream exited")}

      nil ->
        {:error, Error.from_reason(:timeout, "no snapshot arrived in time")}
    end
  end

  # An exit reason other than a single word may hold anything, so only that
  # it was something else is kept.
  defp exit_name(reason) when is_atom(reason), do: reason
  defp exit_name(_reason), do: :other

  # The snapshot comes back as the task's result rather than as a message, so
  # nothing from this stream can mix with a subscribe/2 stream's messages.
  # Only a "full" event is a snapshot: a "diff" carries just the fields that
  # changed, and returning one as the payment would leave out identifiers the
  # caller needs, such as gateway_payment_id for a refund.
  defp fetch_snapshot(url, set, caller) do
    with {:ok, token} <- Auth.token(set) do
      case SSE.first(url, token, "full", caller) do
        :none ->
          {:error, Error.from_reason(:no_snapshot, "the stream closed without a snapshot")}

        result ->
          result
      end
    end
  end

  @doc """
  Returns the receipt for a successful payment or refund, as plain text.

  Returns `{:ok, %{"receipt_text" => text}}`. The text covers the store's name
  and address, the date and time in UTC, the amount, tip and total, card
  details, and the references a receipt needs. Lines with nothing to show are
  left out. Only a payment request whose status is `"SUCCESSFUL"` has one.
  An empty reply returns `{:error, %Teya.Error{reason: :empty_receipt_text}}`.

  A refund has a receipt here when it was made as a payment request, with
  `create/2` and `"transaction_type" => "REFUND"`. One made with
  `Teya.POSLink.Refund.create/2` has no payment request id, so it cannot be
  looked up this way.

  ## Parameters

  - `payment_request_id` — UUID returned from `create/2`

  ## Examples

      {:ok, %{"receipt_text" => text}} = Teya.POSLink.Payment.receipt_text(payment_request_id)
  """
  @spec receipt_text(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def receipt_text(payment_request_id, opts \\ []) do
    path = {"/poslink/v3/payment-requests/:id/receipt-text", id: payment_request_id}

    case Client.request(:get, path, opts) do
      {:ok, body} when is_binary(body) -> receipt_from_text(body)
      result -> result
    end
  end

  # The spec gives a JSON body, which the client decodes to a map. A body left
  # as text is JSON sent under another content type, or a receipt sent as
  # plain text. Either way it comes back in the documented shape. An empty
  # body holds no receipt at all.
  defp receipt_from_text(""),
    do: {:error, Error.from_reason(:empty_receipt_text, "the receipt text was empty")}

  defp receipt_from_text(text) do
    case Jason.decode(text) do
      {:ok, %{"receipt_text" => receipt} = body} when is_binary(receipt) -> {:ok, body}
      _ -> {:ok, %{"receipt_text" => text}}
    end
  end

  @doc """
  Lists a store's payments and refunds, newest first.

  Returns `{:ok, response}` with a `"payment_requests"` list and a
  `"pagination"` map.

  ## Query params (passed as `:params` keyword option)

  - `store_id` — UUID of the store (required)
  - `terminal_id` — filter by terminal
  - `status` — filter by status: `"NEW"`, `"IN_PROGRESS"`, `"SUCCESSFUL"`,
    `"CANCELLING"`, `"CANCELLED"`, `"FAILED"`
  - `transaction_type` — `"SALE"` or `"REFUND"`
  - `start_date_time` — ISO 8601 datetime lower bound
  - `end_date_time` — ISO 8601 datetime upper bound
  - `limit` — results per page, 1–100 (default 10)
  - `offset` — pagination offset (default 0)
  - `sort` — `"ASC"` or `"DESC"`

  ## Example

      Teya.POSLink.Payment.list(params: [store_id: store_id, status: "SUCCESSFUL", limit: 20])
  """
  @spec list(keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def list(opts \\ []) do
    Client.request(:get, "/poslink/v2/payment-requests", opts)
  end

  @doc """
  Subscribes to real-time status updates for a payment request or refund via SSE.

  Spawns a supervised task under `Teya.TaskSupervisor` that opens the SSE
  stream for `payment_request_id` and forwards parsed events as messages to
  `pid` (defaults to `self()`). `opts` takes `:credentials`, the named set of
  credentials to use, as for every call.

  Raises `ArgumentError` in the calling process, before starting the task, for
  an id that cannot be part of a path: `nil`, empty, `"."`, `".."`, or
  anything but text or an integer, or for credentials that are not
  configured. Every other failure arrives as a message.

  ## Messages sent to `pid`

  Every message carries `ref`, the `ref` of the `%Task{}` this returns, so
  two subscriptions to the same payment can be told apart. Pin it when you
  match. If `pid` is not the caller, pass the ref on to it. The ref is `nil`
  only if the caller died before the task could be told it: nobody holds it
  then, and the stream still runs for a recipient that matches any ref.

  - `{:poslink_payment, ref, id, event_type, data}` — a status event where:
    - `id` is the `payment_request_id`
    - `event_type` is `"full"` (complete snapshot) or `"diff"` (partial update)
    - `data` is the decoded JSON map (e.g. `%{"status" => "SUCCESSFUL", ...}`)
  - `{:poslink_payment_error, ref, id, reason}` — the stream ended with an error;
    `reason` is a `%Teya.Error{}`. It has a `status` when the API or the
    token endpoint refused the request. For a network error its `status` is
    `nil` and its `reason` holds the exception, such as
    `%Req.TransportError{reason: :timeout}` when no event arrives within
    `:sse_stream_timeout_ms`. If the task crashes, its `reason` is
    `{:crashed, name}`, with only the exception's name kept

  The task exits normally when the server closes the stream (terminal payment
  state reached) or with an error tuple when the connection fails.

  Failed and cancelled events may carry a `"status_reason"` such as
  `"TERMINAL_UNREACHABLE"` or `"TRANSACTION_ALREADY_IN_PROGRESS"`. Teya may add
  new reasons over time, so handle unknown values.

  ## Example

      {:ok, %Task{ref: ref}} = Teya.POSLink.Payment.subscribe(payment_request_id)

      receive do
        {:poslink_payment, ^ref, ^payment_request_id, "full", %{"status" => "SUCCESSFUL"} = data} ->
          handle_success(data)

        {:poslink_payment, ^ref, ^payment_request_id, _type, %{"status" => "FAILED"} = data} ->
          handle_failure(data)

        {:poslink_payment_error, ^ref, ^payment_request_id, reason} ->
          handle_error(reason)
      end
  """
  @spec subscribe(String.t(), pid() | keyword(), keyword()) :: {:ok, Task.t()}
  def subscribe(payment_request_id, pid_or_opts \\ self())

  # Options with no pid, such as subscribe(id, credentials: :store_b), are
  # for the calling process.
  def subscribe(payment_request_id, opts) when is_list(opts),
    do: subscribe(payment_request_id, self(), opts)

  def subscribe(payment_request_id, pid) when is_pid(pid),
    do: subscribe(payment_request_id, pid, [])

  def subscribe(payment_request_id, pid, opts) when is_pid(pid) and is_list(opts) do
    set = Auth.set_for(opts, :poslink)
    url = stream_url(payment_request_id, set)

    SSE.subscribe(url, set, payment_request_id, pid, :poslink_payment, :poslink_payment_error)
  end

  # Built by the caller, before any task starts, so an id that cannot be a
  # path segment raises where the mistake was made.
  defp stream_url(id, set), do: Client.url({"/poslink/v3/payment-requests/:id", id: id}, set)
end
