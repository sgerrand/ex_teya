defmodule Teya.POSLink.Store do
  @moduledoc """
  POSLink store and terminal discovery.

  Use these endpoints during ePOS registration to identify which `store_id`
  and `terminal_id` to use when creating payment requests.

  Required OAuth scopes: `poslink/stores/get`, `poslink/stores/id/terminals/get`.
  """

  alias Teya.Client

  @doc """
  Lists all stores associated with the merchant account.

  Returns `{:ok, response}` where the body contains a list of store objects,
  each including `store_id`, `name`, and address details.

  ## Options

  - `:params` — query parameters for filtering (implementation-defined by the API)

  ## Examples

      {:ok, %{"stores" => stores}} = Teya.POSLink.Store.list()
  """
  @spec list(keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def list(opts \\ []) do
    Client.request(:get, "/poslink/v1/stores", opts)
  end

  @doc """
  Lists terminals belonging to a store.

  Returns `{:ok, response}` where the body contains a list of terminal objects,
  each including `terminal_id`, `serial_number`, and connectivity status.

  ## Parameters

  - `store_id` — UUID of the store

  ## Examples

      {:ok, %{"terminals" => terminals}} = Teya.POSLink.Store.list_terminals(store_id)
  """
  @spec list_terminals(String.t(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def list_terminals(store_id, opts \\ []) do
    Client.request(:get, "/poslink/v1/stores/#{store_id}/terminals", opts)
  end
end
