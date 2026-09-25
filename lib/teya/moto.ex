defmodule Teya.Moto do
  @moduledoc """
  Mail order and telephone order (MOTO) transactions.

  Use this when the merchant takes the cardholder's details over the phone or
  by post and enters them in a virtual terminal. The card details are sent
  encrypted: your software encrypts `PAN=YYMM=CVV2` with a key Teya provides,
  and passes the ciphertext here. Handling card details, even to encrypt
  them, puts your software within PCI DSS scope.

  For payments on a Teya terminal, see `Teya.POSLink.Payment`. For card data
  read from your own terminal hardware, see `Teya.CardPresent`.

  Teya's specification names no OAuth scope for this endpoint.
  """

  alias Teya.Client

  @doc """
  Processes a MOTO transaction.

  Returns `{:ok, response}` where `response["status"]` is `"SUCCESS"`,
  `"FAILURE"`, or `"PENDING"`, with `transaction_id`, `status_reason`,
  `issuer_result` and `processed_at`.

  ## Required params

  - `type` — `"SALE"` or `"PRE_AUTHORISATION"`
  - `amounts` — `%{"amount" => 1000, "currency" => "GBP"}` (amount in the
    smallest currency unit)
  - `card_details` — `%{"encrypted_card_data" => "...",
    "encryption_key_id" => "...", "encryption_ksn" => "..."}`, and optionally
    `"encryption_mode"` (`"ECB"` or `"CBC"`) and `"encryption_padding"`
    (`"F_PADDING"` or `"PKCS7"`)
  - `transacted_at` — ISO-8601 timestamp, with time zone, of when the
    transaction took place

  ## Optional params

  - `terminal_id` — only when using a terminal not supplied by Teya
  - `merchant_reference` — your own reference for the transaction
  - `dcc` — dynamic currency conversion data, with at least one of
    `"quoted_at"` or `"quote_id"`; see `Teya.DCC`

  ## Options

  - `:idempotency_key` — override the auto-generated idempotency key. Sending
    the same key again returns the first response rather than charging twice

  ## Examples

      {:ok, %{"status" => "SUCCESS", "transaction_id" => id}} =
        Teya.Moto.create(%{
          "type"          => "SALE",
          "amounts"       => %{"amount" => 2500, "currency" => "GBP"},
          "card_details"  => %{
            "encrypted_card_data" => ciphertext,
            "encryption_key_id"   => key_id,
            "encryption_ksn"      => ksn
          },
          "transacted_at" => "2026-09-25T10:30:00Z"
        })
  """
  @spec create(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def create(params, opts \\ []) do
    Client.request(:post, "/v1/transactions/moto", Keyword.put(opts, :body, params))
  end
end
