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
  """

  alias Teya.Client

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
end
