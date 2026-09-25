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
  which. Each entry is a map, usually with `"name"` and `"reason"` keys; read
  them with `Map.get/2`, since the API does not promise every entry has both.
  """

  @type t :: %__MODULE__{
          code: String.t() | nil,
          message: String.t() | nil,
          status: integer() | nil,
          invalid_parameters: [map()] | nil
        }

  defstruct [:code, :message, :status, :invalid_parameters]

  @doc false
  # A Teya error names a code; the description and the list of rejected fields
  # are each there only sometimes.
  def from_response(%{status: status, body: %{"code" => code} = body}) when is_binary(code) do
    %__MODULE__{
      code: code,
      # Teya names it "description". A gateway in front may say "message".
      message: text(body["description"]) || text(body["message"]),
      status: status,
      invalid_parameters: invalid_parameters(body["invalid_parameters"])
    }
  end

  # A gateway or firewall in front often answers with a message and nothing
  # else. Keep that as text rather than as an inspected map.
  def from_response(%{status: status, body: %{"message" => message}}) when is_binary(message) do
    %__MODULE__{status: status, message: message}
  end

  def from_response(%{status: status, body: body}) do
    %__MODULE__{status: status, message: body |> inspect() |> String.slice(0, 500)}
  end

  def from_response(%{status: status}) do
    %__MODULE__{status: status}
  end

  # The message is text, as the type says, whatever arrived.
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  # Keep only what the docs promise, a list of maps, whatever arrived.
  defp invalid_parameters(params) when is_list(params), do: Enum.filter(params, &is_map/1)
  defp invalid_parameters(_params), do: nil

  @doc false
  # The token endpoint answers in the OAuth 2.0 error format: an "error" code,
  # sometimes with an "error_description". OAuth codes are short words joined
  # by underscores, such as "invalid_client" or, with a 503,
  # "temporarily_unavailable". A rate limiter or firewall may send
  # {"error": "Too Many Requests"} instead; that is a message, not a code a
  # caller could match on, so it is kept as one.
  #
  # A body that also names a Teya "code" is read as a Teya error, which keeps
  # both that code and its message.
  def from_oauth_response(%{body: %{"code" => code}} = resp) when is_binary(code),
    do: from_response(resp)

  def from_oauth_response(%{status: status, body: %{"error" => error} = body})
      when is_binary(error) do
    if oauth_code?(error),
      do: %__MODULE__{code: error, message: text(body["error_description"]), status: status},
      else: %__MODULE__{message: error, status: status}
  end

  def from_oauth_response(resp), do: from_response(resp)

  defp oauth_code?(error), do: String.match?(error, ~r/\A[a-z0-9_]+\z/)
end
