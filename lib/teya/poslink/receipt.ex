defmodule Teya.POSLink.Receipt do
  @moduledoc """
  POSLink receipt printing — send print jobs to a terminal's receipt printer.

  A receipt request enqueues a print job on the terminal. The job transitions
  through: `NOT_PRINTED` → `ENQUEUED` → `PRINTING` → `PRINTED` | `FAILED`.

  Use `create/2` to submit the receipt and `subscribe_status/2` to receive
  real-time printer status updates via SSE.

  Required OAuth scopes: `poslink/receipt-requests/create`,
  `poslink/receipt-requests/id/status/get`.
  """

  alias Teya.{Auth, Client, Error, SSE}

  @doc """
  Submits a receipt print request to a terminal.

  Returns `{:ok, response}` containing the `receipt_id` and initial `status`
  (`"NOT_PRINTED"` or `"ENQUEUED"`). Use the returned `receipt_id` with
  `subscribe_status/2` to stream printer status updates.

  ## Required params

  - `store_id` — UUID of the store
  - `terminal_id` — UUID of the target terminal
  - `content` — the receipt content; a map with either:
    - `%{"type" => "JSON", "data" => %{...}}` for structured JSON receipts, or
    - `%{"type" => "IMAGE", "data" => base64_string}` for image receipts

  ## Optional params

  - `merchant_reference` — caller-supplied reference (max 60 chars)

  ## Options

  - `:idempotency_key` — override the auto-generated idempotency key
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/poslink/v1/receipt-requests", Keyword.put(opts, :body, params))
  end

  @doc """
  Subscribes to real-time printer status updates for a receipt request via SSE.

  Spawns a supervised task under `Teya.TaskSupervisor` that opens the SSE
  stream for `receipt_id` and forwards parsed events as messages to `pid`
  (defaults to `self()`).

  ## Messages sent to `pid`

  - `{:poslink_receipt, id, event_type, data}` — a status event where:
    - `id` is the `receipt_id`
    - `event_type` is `"full"` (complete snapshot) or `"diff"` (partial update)
    - `data` is the decoded JSON map (e.g. `%{"status" => "PRINTED", ...}`)
  - `{:poslink_receipt_error, id, reason}` — the stream ended with an error;
    `reason` is a `%Teya.Error{}` or a transport exception

  ## Example

      {:ok, _task} = Teya.POSLink.Receipt.subscribe_status(receipt_id)

      receive do
        {:poslink_receipt, ^receipt_id, "full", %{"status" => "PRINTED"}} ->
          :ok

        {:poslink_receipt, ^receipt_id, _type, %{"status" => "FAILED"}} ->
          handle_print_failure()

        {:poslink_receipt_error, ^receipt_id, reason} ->
          handle_error(reason)
      end
  """
  @spec subscribe_status(String.t(), pid()) :: {:ok, Task.t()}
  def subscribe_status(receipt_id, pid \\ self()) do
    task =
      Task.Supervisor.async_nolink(Teya.TaskSupervisor, fn ->
        stream_receipt(receipt_id, pid)
      end)

    {:ok, task}
  end

  defp stream_receipt(id, pid) do
    with {:ok, token} <- Auth.token() do
      base_url = Application.get_env(:teya, :base_url, "https://api.teya.com")
      url = base_url <> "/poslink/v1/receipt-requests/#{id}/status"

      req_opts =
        Application.get_env(
          :teya,
          :sse_req_options,
          Application.get_env(:teya, :req_options, [])
        )

      case Req.get(url, [auth: {:bearer, token}, into: :self] ++ req_opts) do
        {:ok, %{status: 200, body: %Req.Response.Async{ref: ref}}} ->
          receive_loop(ref, "", id, pid)

        {:ok, resp} ->
          send(pid, {:poslink_receipt_error, id, Error.from_response(resp)})

        {:error, reason} ->
          send(pid, {:poslink_receipt_error, id, reason})
      end
    else
      {:error, reason} ->
        send(pid, {:poslink_receipt_error, id, reason})
    end
  end

  defp receive_loop(ref, buffer, id, pid) do
    receive do
      {^ref, {:data, chunk}} ->
        {events, rest} = SSE.parse(buffer <> chunk)

        Enum.each(events, fn event ->
          event_type = Map.get(event, "event")

          case Jason.decode(Map.get(event, "data", "null")) do
            {:ok, data} when is_map(data) ->
              send(pid, {:poslink_receipt, id, event_type, data})

            _ ->
              :ok
          end
        end)

        receive_loop(ref, rest, id, pid)

      {^ref, :done} ->
        :ok

      {^ref, {:error, reason}} ->
        send(pid, {:poslink_receipt_error, id, reason})
    end
  end
end
