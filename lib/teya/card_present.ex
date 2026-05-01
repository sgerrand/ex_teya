defmodule Teya.CardPresent do
  @moduledoc """
  Card-present transactions via direct terminal integration.

  Use this when your software communicates directly with POS hardware and
  supplies low-level card data (EMV TLV, encrypted track, PIN block). For
  Teya-managed terminals accessed through ePOS middleware, see
  `Teya.POSLink.Payment` instead.

  Required OAuth scope: `transactions/card-present/create`.
  """

  alias Teya.Client

  @doc """
  Processes a card-present transaction.

  Returns `{:ok, response}` where `response["status"]` is `"SUCCESS"`,
  `"FAILURE"`, or `"PENDING"`.

  ## Required params

  - `type` — `"SALE"` or `"PRE_AUTHORISATION"`
  - `entry_mode` — `"CONTACTLESS_EMV"`, `"CONTACT_EMV"`, `"CONTACT_MAGSTRIPE"`,
    `"CONTACT_MAGSTRIPE_FALLBACK"`, `"CONTACTLESS_MAGSTRIPE"`, or `"MANUAL_ENTRY"`
  - `amounts` — `%{"amount" => 1000, "currency" => "GBP"}` (amount in smallest unit)
  - `emv_data` — hex-encoded TLV EMV data string
  - `track_data` — `%{"encryption_key_id" => "...", "encrypted_track" => "...",
    "encryption_ksn" => "..."}`
  - `transacted_at` — ISO-8601 timestamp of when the transaction occurred on-device

  ## Optional params

  - `verification_method` — `"CONSUMER_DEVICE"`, `"NO_CVM"`, `"ONLINE_PIN"`,
    `"OFFLINE_ENCRYPTED_PIN"`, `"OFFLINE_PLAINTEXT_PIN"`, or `"SIGNATURE"`
  - `merchant_reference` — client-side identifier (1–60 chars)
  - `authentication_retry` — `true` if this is a re-attempt with additional authentication
  - `terminal_data` — `%{"entry_mode_extra_capabilities" => [...],
    "cvm_extra_capabilities" => [...]}`
  - `pin_block` — `%{"block" => "...", "format" => "ISO_FORMAT_0",
    "encryption_key_id" => "...", "encryption_ksn" => "..."}`
  - `card_data` — `%{"number" => "...", "expiry_month" => "MM", "expiry_year" => "YYYY"}`
  - `dcc` — `%{"quoted_at" => "...", "cardholder_amount" =>
    %{"amount" => 1000, "currency" => "EUR"}}`

  ## Options

  - `idempotency_key` — override the auto-generated idempotency key

  ## Examples

      params = %{
        "type"          => "SALE",
        "entry_mode"    => "CONTACT_EMV",
        "amounts"       => %{"amount" => 1000, "currency" => "GBP"},
        "emv_data"      => "9F2608AABBCCDD112233",
        "track_data"    => %{
          "encryption_key_id" => "key-1",
          "encrypted_track"   => "...",
          "encryption_ksn"    => "ksn-1"
        },
        "transacted_at" => "2025-05-01T12:00:00Z"
      }

      {:ok, response} = Teya.CardPresent.create(params)
      response["status"]  # "SUCCESS" | "FAILURE" | "PENDING"
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/v1/transactions/card-present", Keyword.put(opts, :body, params))
  end
end
