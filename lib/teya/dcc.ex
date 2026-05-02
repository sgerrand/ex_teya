defmodule Teya.DCC do
  @moduledoc """
  Dynamic Currency Conversion (DCC) rate quotes.

  Before processing a card-present transaction, call `quote/1` to check whether
  the cardholder's card is eligible for DCC and retrieve the current exchange
  rate. If eligible, offer the cardholder the choice to pay in their home
  currency. If accepted, pass the returned quote data in the `dcc` field of
  `Teya.CardPresent.create/2`.

  This endpoint does not require OAuth authentication.
  """

  alias Teya.Error

  @doc """
  Checks DCC eligibility and returns an exchange rate quote.

  Returns `{:ok, offer}` when the card is eligible. Notable error codes:

  - `"NON_ELIGIBLE_CARD"` — BIN is not eligible for DCC; proceed without DCC
  - `"SAME_CURRENCY"` — cardholder currency matches base currency; proceed without DCC
  - `"UNSUPPORTED_CURRENCY"` — currency pair not supported

  ## Required params

  - `store_id` — business identifier for the quote
  - `card_first9` — first 6–9 digits of the card number
  - `base_amount` — transaction amount in the smallest unit of `base_currency`
  - `base_currency` — ISO-4217 transaction currency (e.g. `"GBP"`)

  ## Optional params

  - `cardholder_currency` — ISO-4217 currency code of the cardholder's card

  ## Response fields

  - `quote_id` — unique quote identifier
  - `quoted_at` — ISO-8601 timestamp of the quote
  - `exchange_rate` — rate with 6 decimal places
  - `markup` — additional markup percentage
  - `cardholder_currency` — resolved card currency
  - `cardholder_amount` — amount in card currency minor units
  - `ecb_markup` — ECB rate markup (EEA currencies only)

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
            "quoted_at"          => offer["quoted_at"],
            "cardholder_amount"  => %{
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
  @spec quote(map()) :: {:ok, map()} | {:error, Teya.Error.t()}
  def quote(params) do
    base_url = Application.get_env(:teya, :base_url, "https://api.teya.com")
    req_opts = Application.get_env(:teya, :dcc_req_options, [])

    req =
      [
        method: :post,
        url: base_url <> "/fx/v3/dcc",
        json: params,
        receive_timeout: 30_000
      ]
      |> Keyword.merge(req_opts)

    case Req.request(req) do
      {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, resp.body}
      {:ok, resp} -> {:error, Error.from_response(resp)}
      {:error, reason} -> {:error, reason}
    end
  end
end
