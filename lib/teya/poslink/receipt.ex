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

  alias Teya.Client

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
end
