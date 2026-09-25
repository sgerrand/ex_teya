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

  @doc """
  Returns the configuration that applies to a terminal in a store.

  Returns `{:ok, %{"configs" => configs}}`, each entry with `config_key`,
  `value` and `updated_at`. Teya records the terminal as it asks, so later
  changes to the store's configuration are pushed to it.

  ## Parameters

  - `store_id` — UUID of the store
  - `terminal_id` — the terminal's id

  ## Examples

      {:ok, %{"configs" => configs}} =
        Teya.POSLink.Store.terminal_configs(store_id, terminal_id)
  """
  @spec terminal_configs(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Teya.Error.t()}
  def terminal_configs(store_id, terminal_id, opts \\ []) do
    Client.request(:get, "/poslink/v1/stores/#{store_id}/terminals/#{terminal_id}/configs", opts)
  end

  @doc """
  Sets a configuration value for every terminal in a store.

  Values are strings, and which ones are accepted depends on the key: for
  example, `"PAT_ENABLED"` takes `"true"` or `"false"`, and anything else is
  refused with a 400. Setting the value it already has changes nothing.

  Returns `{:ok, response}` with `config_key`, `value` and `updated_at`.

  ## Parameters

  - `store_id` — UUID of the store
  - `config_key` — the setting to change, such as `"PAT_ENABLED"`
  - `value` — the new value, as a string

  ## Examples

      {:ok, %{"value" => "true"}} =
        Teya.POSLink.Store.put_config(store_id, "PAT_ENABLED", "true")
  """
  @spec put_config(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Teya.Error.t()}
  def put_config(store_id, config_key, value, opts \\ []) do
    Client.request(
      :put,
      "/poslink/v1/stores/#{store_id}/configs/#{config_key}",
      Keyword.put(opts, :body, %{"value" => value})
    )
  end
end
