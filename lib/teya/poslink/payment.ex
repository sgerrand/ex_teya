defmodule Teya.POSLink.Payment do
  @moduledoc """
  POSLink payment requests — initiate and manage card-present payments at terminals.

  A payment request instructs a specific terminal to collect a card payment.
  Status transitions: `NEW` → `IN_PROGRESS` → `SUCCESSFUL` | `FAILED` | `CANCELLED`.

  Use `create/2` to start a payment and `subscribe/2` to receive real-time
  status updates via the terminal's SSE stream.

  Required OAuth scopes: `poslink/payment-requests/create`,
  `poslink/payment-requests/id/get`, `poslink/payment-requests/id/update`,
  `poslink/payment-requests/get`.

  ## Task lifecycle

  `subscribe/2` returns `{:ok, %Task{}}` immediately. The task runs under
  `Teya.TaskSupervisor` with `async_nolink`, meaning:

  - The task is **not linked** to the caller — a task crash does not take down
    the calling process.
  - The supervisor does **not restart** the task if it exits.
  - If the **caller process dies**, the task continues running until the SSE
    stream ends or errors, then exits normally.
  - If the **SSE stream disconnects** mid-payment (network error, server
    restart), the task sends `{:poslink_payment_error, id, reason}` and exits.
    There is no automatic reconnection. To recover, call `get/2` to fetch the
    current status, or call `subscribe/2` again to open a fresh stream. A new
    stream always starts with a full snapshot of the payment request.
  """

  alias Teya.{Auth, Client, SSE}

  @collector_grace_ms 500

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
        "store_id"         => store_id,
        "terminal_id"      => terminal_id,
        "requested_amount"   => %{"amount" => 1000, "currency" => "GBP"},
        "transaction_type"   => "SALE",
        "merchant_reference" => "order-1234"
      }

      {:ok, %{"payment_request_id" => id}} = Teya.POSLink.Payment.create(params)
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/poslink/v3/payment-requests", Keyword.put(opts, :body, params))
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
      "/poslink/v2/payment-requests/#{payment_request_id}",
      Keyword.put(opts, :body, body)
    )
  end

  @doc """
  Fetches the current state of a single payment request or refund by its ID.

  The POSLink API has no plain JSON endpoint for a single payment request.
  This function opens the status stream, returns the first snapshot, and then
  closes the stream.

  Useful as a fallback when an SSE stream from `subscribe/2` disconnects before
  the payment reaches a terminal state — check the current status, then
  re-subscribe if still in progress.

  ## Parameters

  - `payment_request_id` — UUID returned from `create/2`

  ## Options

  - `:timeout` — milliseconds to wait for the snapshot (default `30_000`);
    returns `{:error, :timeout}` when it runs out

  ## Examples

      {:ok, payment} = Teya.POSLink.Payment.get(payment_request_id)
      payment["status"]  # "NEW" | "IN_PROGRESS" | "SUCCESSFUL" | "FAILED" | "CANCELLING" | "CANCELLED"
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(payment_request_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    collector =
      Task.Supervisor.async_nolink(Teya.TaskSupervisor, fn ->
        await_snapshot(payment_request_id, timeout)
      end)

    outcome = Task.yield(collector, timeout + @collector_grace_ms)
    Task.shutdown(collector, :brutal_kill)

    case outcome do
      {:ok, result} -> result
      # No answer in time, or the collector died without sending one.
      _ -> {:error, :timeout}
    end
  end

  # Runs in the collector task, so the stream's messages land in a mailbox of
  # its own. Receiving them in the caller would take messages belonging to a
  # subscribe/2 stream the caller already had open for the same payment.
  defp await_snapshot(payment_request_id, timeout) do
    {:ok, stream} = subscribe(payment_request_id, self())
    ref = stream.ref

    result =
      receive do
        # A "diff" carries only the fields that changed, so it is not a
        # snapshot. Leave it and wait for one.
        {:poslink_payment, ^payment_request_id, type, data} when type != "diff" -> {:ok, data}
        {:poslink_payment_error, ^payment_request_id, reason} -> {:error, reason}
        {^ref, _} -> {:error, :no_event}
      after
        timeout -> {:error, :timeout}
      end

    Task.shutdown(stream, :brutal_kill)
    result
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
  `pid` (defaults to `self()`).

  ## Messages sent to `pid`

  - `{:poslink_payment, id, event_type, data}` — a status event where:
    - `id` is the `payment_request_id`
    - `event_type` is `"full"` (complete snapshot) or `"diff"` (partial update)
    - `data` is the decoded JSON map (e.g. `%{"status" => "SUCCESSFUL", ...}`)
  - `{:poslink_payment_error, id, reason}` — the stream ended with an error;
    `reason` is a `%Teya.Error{}`, a transport exception, or `:stream_timeout`

  The task exits normally when the server closes the stream (terminal payment
  state reached) or with an error tuple when the connection fails.

  Failed and cancelled events may carry a `"status_reason"` such as
  `"TERMINAL_UNREACHABLE"` or `"TRANSACTION_ALREADY_IN_PROGRESS"`. Teya may add
  new reasons over time, so handle unknown values.

  ## Example

      {:ok, _task} = Teya.POSLink.Payment.subscribe(payment_request_id)

      receive do
        {:poslink_payment, ^payment_request_id, "full", %{"status" => "SUCCESSFUL"} = data} ->
          handle_success(data)

        {:poslink_payment, ^payment_request_id, _type, %{"status" => "FAILED"} = data} ->
          handle_failure(data)

        {:poslink_payment_error, ^payment_request_id, reason} ->
          handle_error(reason)
      end
  """
  @spec subscribe(String.t(), pid()) :: {:ok, Task.t()}
  def subscribe(payment_request_id, pid \\ self()) do
    task =
      Task.Supervisor.async_nolink(Teya.TaskSupervisor, fn ->
        stream_payment(payment_request_id, pid)
      end)

    {:ok, task}
  end

  defp stream_payment(id, pid) do
    case Auth.token() do
      {:ok, token} ->
        base_url = Application.get_env(:teya, :base_url, "https://api.teya.com")
        url = base_url <> "/poslink/v3/payment-requests/#{id}"

        req_opts =
          Application.get_env(
            :teya,
            :sse_req_options,
            Application.get_env(:teya, :req_options, [])
          )

        SSE.stream(url, token, id, :poslink_payment, :poslink_payment_error, pid, req_opts)

      {:error, reason} ->
        send(pid, {:poslink_payment_error, id, reason})
    end
  end
end
