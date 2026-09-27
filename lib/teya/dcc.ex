defmodule Teya.DCC do
  @moduledoc """
  Dynamic Currency Conversion (DCC) offers.

  Before processing a card-present transaction, call `quote/2` to check whether
  the cardholder's card is eligible for DCC and get an offer at the current
  exchange rate. Teya keeps the quote behind the offer. If eligible, offer the
  cardholder the choice to pay in their home currency. If they accept, pass
  the offer's `quote_id` and amount in the `dcc` field of
  `Teya.CardPresent.create/2` or `Teya.Moto.create/2`.

  Needs the `fx/dcc/create` scope.
  """

  alias Teya.Client

  @doc """
  Checks DCC eligibility and creates an offer with a quote.

  Returns `{:ok, offer}` when the card is eligible. Notable error codes:

  - `"NON_ELIGIBLE_CARD"` — BIN is not eligible for DCC; proceed without DCC
  - `"SAME_CURRENCY"` — cardholder currency matches base currency; proceed without DCC
  - `"UNSUPPORTED_CURRENCY"` — currency pair not supported
  - `"DCC_DISABLED"` — DCC is turned off for the store
  - `"BELOW_MINIMUM"` — the amount is too small for DCC

  ## Required params

  - `store_id` — UUID of the store
  - `card_first9` — first 6–9 digits of the card number
  - `base_amount` — transaction amount, tips included, in the smallest unit
    of `base_currency`
  - `base_currency` — ISO-4217 transaction currency (e.g. `"GBP"`)

  ## Optional params

  - `cardholder_currency` — ISO-4217 currency code of the cardholder's card;
    found from the card number when left out

  ## Response fields

  - `quote_id` — the quote's UUID, to pass on with the payment
  - `exchange_rate` — rate with 6 decimal places
  - `markup` — markup over the latest exchange rate
  - `ecb_markup` — markup over the ECB rate (EEA currencies only, else `nil`)
  - `cardholder_currency` — the card's currency
  - `cardholder_amount` — amount in the card currency's minor units

  ## Examples

      case Teya.DCC.quote(%{
        "store_id"      => store_id,
        "card_first9"   => "411111111",
        "base_amount"   => 1000,
        "base_currency" => "GBP"
      }) do
        {:ok, offer} ->
          # offer the cardholder: pay offer["cardholder_amount"] offer["cardholder_currency"]
          # if accepted, include in Teya.CardPresent.create/2 params:
          dcc_params = %{
            "quote_id"          => offer["quote_id"],
            "cardholder_amount" => %{
              "amount"   => offer["cardholder_amount"],
              "currency" => offer["cardholder_currency"]
            }
          }
          Teya.CardPresent.create(Map.put(card_present_params, "dcc", dcc_params))

        {:error, %Teya.Error{code: code}} when code in ["NON_ELIGIBLE_CARD", "SAME_CURRENCY"] ->
          # card not eligible — proceed without DCC
          Teya.CardPresent.create(card_present_params)
      end
  """
  @spec quote(map(), keyword()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def quote(params, opts \\ []) do
    Client.request(:post, "/fx/v1/dcc/offers", Keyword.put(opts, :body, params))
  end
end
