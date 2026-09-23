defmodule Teya.Error do
  @moduledoc """
  Represents an error returned by the Teya API.

  Pattern-match on `code` for Teya-specific error codes. Codes shared by most
  endpoints are `"BAD_REQUEST"`, `"UNAUTHORISED"`, `"FORBIDDEN"`,
  `"NOT_FOUND"`, `"CONFLICT"`, `"GONE"`, `"UNSUPPORTED_MEDIA_TYPE"`,
  `"TOO_MANY_REQUESTS"` and `"INTERNAL_SERVER_ERROR"`.

  Payment endpoints add codes describing why a card was declined, such as
  `"INSUFFICIENT_FUNDS"`, `"CARD_EXPIRED"`, `"BLOCKED_CARD"` and
  `"SUSPECTED_FRAUD"`. Teya adds codes over time, so handle unknown values.

  Token endpoint failures use the OAuth 2.0 error format instead, giving codes
  such as `"invalid_client"` and `"invalid_scope"`.

  `invalid_parameters` lists the request fields the API rejected, when it says
  which. Each entry is a map with `"name"` and `"reason"` keys.
  """

  @type t :: %__MODULE__{
          code: String.t() | nil,
          message: String.t() | nil,
          status: integer() | nil,
          invalid_parameters: [map()] | nil
        }

  defstruct [:code, :message, :status, :invalid_parameters]

  @doc false
  def from_response(%{status: status, body: %{"code" => code, "description" => message} = body}) do
    %__MODULE__{
      code: code,
      message: message,
      status: status,
      invalid_parameters: body["invalid_parameters"]
    }
  end

  def from_response(%{status: status, body: body}) do
    %__MODULE__{status: status, message: body |> inspect() |> String.slice(0, 500)}
  end

  def from_response(%{status: status}) do
    %__MODULE__{status: status}
  end

  @doc false
  # The token endpoint answers in the OAuth 2.0 error format, which RFC 6749
  # sends as 400, or 401 for a bad client. Any other status in front of that
  # endpoint is a gateway or proxy page, so keep its body as the message
  # rather than reading a non-OAuth string as a code.
  def from_oauth_response(%{status: status, body: %{"error" => code} = body})
      when is_binary(code) and status in [400, 401] do
    %__MODULE__{code: code, message: body["error_description"], status: status}
  end

  def from_oauth_response(resp), do: from_response(resp)
end
