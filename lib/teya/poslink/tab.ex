defmodule Teya.POSLink.Tab do
  @moduledoc """
  POSLink tabs, for Pay at Table: a table's bill, which the ePOS keeps and
  a terminal shows and takes payment for.

  The ePOS creates a tab when a table opens, keeps its total up to date, and
  sends the bill when a terminal asks to show it. A terminal pays a tab
  through a payment request linked to it: `Teya.POSLink.Payment.create/2`
  with `tab_id` and `payment_type`. The ePOS closes the tab when it is done
  with it.

  A tab's `status` is one of:

  - `"OPEN"` — taking items and amendments
  - `"PAYING"` — a payment is under way
  - `"PAUSED"` — a split payment was paused partway
  - `"COMPLETED"` — paid in full
  - `"CLOSED"` — closed by the ePOS; the record is kept

  This module covers the calls the ePOS makes. The terminal's own calls,
  such as asking to show the bill or to start a payment, are made by Teya's
  terminals.

  Teya's specification names no scope for these endpoints. If they answer
  401 or 403 with the scopes ePOS registration gave you, ask Teya which they
  need.
  """

  alias Teya.Client

  @doc """
  Creates a tab for a store. The tab starts `"OPEN"`.

  Returns `{:ok, tab}` with its `tab_id`, `status`, `total_amount`,
  `total_paid`, `remaining` and `payment_requests`.

  The request carries an `Idempotency-Key`, as Teya's specification
  requires: your own, or one made up. Sending the same key and body again
  returns the same tab. Teya keeps keys for at least 24 hours, per store.
  With `:retry_idempotent_posts` set, the request is retried as described in
  the README.

  Teya answers 409 in two cases:

  - the same key was sent with a different body
  - the store already has a tab with this `merchant_reference`

  The second can mean an earlier call made the tab but its answer was lost,
  and the call was made again with a new key. Look the tab up by its
  reference before you make a new one. Name every status, so a tab that is
  already completed or closed is found too:

      Teya.POSLink.Tab.list(store_id,
        params: [
          merchant_reference: reference,
          status: ["OPEN", "PAYING", "PAUSED", "COMPLETED", "CLOSED"]
        ]
      )

  ## Required params

  - `store_id` — UUID of the store
  - `tab_name` — the name a terminal shows, such as a table number (max 100
    chars)
  - `merchant_reference` — your own reference for the tab, unique per store
    (max 100 chars)
  - `currency_code` — ISO 4217 currency code, such as `"GBP"`

  ## Optional params

  - `epos_instance_id` — identifier of the ePOS instance making the request
    (max 100 chars)

  ## Options

  - `:idempotency_key` — your own key, as text or an integer (max 64 chars)

  ## Examples

      {:ok, %{"tab_id" => tab_id}} =
        Teya.POSLink.Tab.create(%{
          "store_id"           => store_id,
          "tab_name"           => "Table 4",
          "merchant_reference" => "table-4-1830",
          "currency_code"      => "GBP"
        })
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.idempotent_post("/poslink/v1/tabs", Keyword.put(opts, :body, params))
  end

  @doc """
  Lists a store's tabs, a page at a time.

  Returns `{:ok, response}` with a `"tabs"` list and a `"paging"` map, whose
  `"cursors"` hold the `before` and `after` cursors for the pages either
  side.

  With no `status`, only active tabs are listed: `"OPEN"`, `"PAYING"` and
  `"PAUSED"`. Ask for `"COMPLETED"` or `"CLOSED"` by name to include them.

  Raises `ArgumentError`, before any request, if `store_id` is `nil` or
  empty, if `:params` holds a `store_id`, since the store is the first
  argument, or if `:params` holds an empty list, such as `status: []`, which
  would ask for nothing. Leave `status` out to get Teya's default.

  ## Query params (passed as `:params`)

  - `status` — a status, or a list of them, such as `["OPEN", "PAUSED"]`
  - `merchant_reference` — the tab with this reference, if any
  - `after` — the cursor of the page before the one wanted
  - `before` — the cursor of the page after the one wanted; not with `after`
  - `limit` — tabs per page, up to 300 (default 50)

  ## Examples

      {:ok, %{"tabs" => tabs}} = Teya.POSLink.Tab.list(store_id)

      {:ok, %{"tabs" => tabs}} =
        Teya.POSLink.Tab.list(store_id, params: [status: ["COMPLETED", "CLOSED"], limit: 100])
  """
  @spec list(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def list(store_id, opts \\ [])

  def list(store_id, _opts) when store_id in [nil, ""] do
    raise ArgumentError, "Tab.list/2 needs a store id, got: #{inspect(store_id)}"
  end

  def list(store_id, opts) do
    params = [{:store_id, store_id} | query(Keyword.get(opts, :params))]
    Client.request(:get, "/poslink/v1/tabs", Keyword.put(opts, :params, params))
  end

  # A list value, such as several statuses, is sent as the key repeated,
  # as the specification asks: status=OPEN&status=PAUSED.
  defp query(nil), do: []

  defp query(params) do
    Enum.flat_map(params, fn
      {key, _value} when key in [:store_id, "store_id"] ->
        raise ArgumentError,
              "Tab.list/2 takes the store as its first argument, not as store_id in :params"

      {key, []} ->
        raise ArgumentError,
              "#{inspect(key)} in :params is an empty list, which asks for nothing; " <>
                "leave it out to get Teya's default"

      {key, values} when is_list(values) ->
        for value <- values, do: {key, value}

      pair ->
        [pair]
    end)
  end

  @doc """
  Fetches a tab, with its items and payment requests.

  ## Examples

      {:ok, %{"status" => status, "remaining" => remaining}} = Teya.POSLink.Tab.get(tab_id)
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def get(tab_id, opts \\ []) do
    Client.request(:get, {"/poslink/v1/tabs/:id", id: tab_id}, opts)
  end

  @doc """
  Updates a tab's total or items, as the bill changes.

  Only the fields given are changed. The tab must take changes, which
  usually means it is `"OPEN"`. Returns `{:ok, tab}`.

  Raises `ArgumentError` if given an `:idempotency_key`: Teya documents no
  `Idempotency-Key` header for this endpoint, so none is sent.

  ## Params

  - `total_amount` — `%{"amount" => 4250, "currency" => "GBP"}`, in minor
    units
  - `tab_item_data` — the items, each `%{"name" => ..., "quantity" => ...,
    "amount" => ...}`

  ## Examples

      {:ok, _tab} =
        Teya.POSLink.Tab.update(tab_id, %{
          "total_amount" => %{"amount" => 4250, "currency" => "GBP"}
        })
  """
  @spec update(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def update(tab_id, params, opts \\ []) do
    Client.request(:patch, {"/poslink/v1/tabs/:id", id: tab_id}, Keyword.put(opts, :body, params))
  end

  @doc """
  Closes a tab. Its status becomes `"CLOSED"`, and Teya keeps the record.

  Returns `{:ok, %{"tab_id" => ..., "status" => "CLOSED", "closed_at" => ...}}`.

  A tab that is `"OPEN"`, `"PAUSED"` or `"COMPLETED"` can be closed. One that
  is `"PAYING"` cannot, since a payment is under way. A tab already closed
  answers with an error, so closing twice is not safe to treat as done.

  Raises `ArgumentError` if given an `:idempotency_key`: Teya documents no
  `Idempotency-Key` header for this endpoint, so none is sent.

  ## Examples

      {:ok, %{"status" => "CLOSED"}} = Teya.POSLink.Tab.close(tab_id)
  """
  @spec close(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def close(tab_id, opts \\ []) do
    Client.request(:delete, {"/poslink/v1/tabs/:id", id: tab_id}, opts)
  end

  @doc """
  Sends the bill for a tab, for the terminal that asked to show it.

  Teya passes it on to the terminal that holds the tab's show-bill request.
  Returns `{:ok, response}` with the tab's `status` and the
  `showing_bill_terminal_id`.

  Raises `ArgumentError` if given an `:idempotency_key`: Teya documents no
  `Idempotency-Key` header for this endpoint, so none is sent.

  ## Required params

  - `terminal_id` — the terminal showing the bill
  - `total_amount` — `%{"amount" => 4250, "currency" => "GBP"}`, in minor
    units

  ## Optional params

  - `print_model` — the bill's layout, as `%{"rows" => [...]}`
  - `tab_item_data` — the items, each `%{"name" => ..., "quantity" => ...,
    "amount" => ...}`

  ## Examples

      {:ok, _} =
        Teya.POSLink.Tab.send_bill(tab_id, %{
          "terminal_id"   => terminal_id,
          "total_amount"  => %{"amount" => 4250, "currency" => "GBP"},
          "tab_item_data" => [%{"name" => "Fish pie", "quantity" => 2, "amount" => 2800}]
        })
  """
  @spec send_bill(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def send_bill(tab_id, params, opts \\ []) do
    Client.request(
      :post,
      {"/poslink/v1/tabs/:id/bill", id: tab_id},
      Keyword.put(opts, :body, params)
    )
  end

  @doc """
  Tells a terminal that the ePOS cannot do what it asked for a tab, so the
  terminal can show the operator why.

  Returns `{:ok, response}` with the tab's `status`.

  Raises `ArgumentError` if given an `:idempotency_key`: Teya documents no
  `Idempotency-Key` header for this endpoint, so none is sent.

  ## Required params

  - `terminal_id` — the terminal that asked
  - `error_code` — `"TABLE_NOT_FOUND"`, `"BILL_ALREADY_SETTLED"`,
    `"EPOS_ERROR"` or `"REQUEST_REJECTED"`
  - `message` — a message the terminal can show

  ## Examples

      {:ok, _} =
        Teya.POSLink.Tab.report_error(tab_id, %{
          "terminal_id" => terminal_id,
          "error_code"  => "BILL_ALREADY_SETTLED",
          "message"     => "This bill has been paid at the till."
        })
  """
  @spec report_error(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def report_error(tab_id, params, opts \\ []) do
    Client.request(
      :post,
      {"/poslink/v1/tabs/:id/errors", id: tab_id},
      Keyword.put(opts, :body, params)
    )
  end
end
