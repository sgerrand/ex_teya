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
    There is no automatic reconnection. To recover, call `Payment.get/1` or
    `Payment.list/1` to poll the current status, or call `subscribe/2` again to
    open a fresh stream.
  """

  alias Teya.{Auth, Client, SSE}

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

  ## Optional params

  - `merchant_reference` — caller-supplied reference (max 60 chars)
  - `transaction_type` — currently only `"SALE"` (default)
  - `metadata` — arbitrary key/value pairs (max 10 keys)

  ## Options

  - `:idempotency_key` — override the auto-generated idempotency key

  ## Examples

      params = %{
        "store_id"         => store_id,
        "terminal_id"      => terminal_id,
        "requested_amount" => %{"amount" => 1000, "currency" => "GBP"}
      }

      {:ok, %{"payment_request_id" => id}} = Teya.POSLink.Payment.create(params)
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/poslink/v2/payment-requests", Keyword.put(opts, :body, params))
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
  Fetches the current state of a single payment request by its ID.

  Useful as a fallback when an SSE stream from `subscribe/2` disconnects before
  the payment reaches a terminal state — check the current status, then
  re-subscribe if still in progress.

  ## Parameters

  - `payment_request_id` — UUID returned from `create/2`

  ## Examples

      {:ok, payment} = Teya.POSLink.Payment.get(payment_request_id)
      payment["status"]  # "NEW" | "IN_PROGRESS" | "SUCCESSFUL" | "FAILED" | "CANCELLED"
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def get(payment_request_id, opts \\ []) do
    Client.request(:get, "/poslink/v2/payment-requests/#{payment_request_id}", opts)
  end

  @doc """
  Lists payment requests with optional filtering.

  Returns `{:ok, response}` containing a paginated list of payment request
  objects and pagination metadata.

  ## Optional params (passed as `:params` keyword option)

  - `status` — filter by status: `"NEW"`, `"IN_PROGRESS"`, `"SUCCESSFUL"`,
    `"CANCELLING"`, `"CANCELLED"`, `"FAILED"`
  - `store_id` — UUID to filter by store
  - `from` — ISO 8601 datetime lower bound (inclusive)
  - `to` — ISO 8601 datetime upper bound (inclusive)
  - `limit` — max results per page (default varies)
  - `offset` — pagination offset

  ## Example

      Teya.POSLink.Payment.list(params: [status: "SUCCESSFUL", limit: 20])
  """
  @spec list(keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def list(opts \\ []) do
    Client.request(:get, "/poslink/v1/payment-requests", opts)
  end

  @doc """
  Subscribes to real-time status updates for a payment request via SSE.

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
        url = base_url <> "/poslink/v2/payment-requests/#{id}"

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
