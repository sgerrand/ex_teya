defmodule Teya.Error do
  @moduledoc """
  A failed request: one Teya refused, or one with no usable answer.

  Pattern-match on `code` for Teya-specific error codes. Codes shared by most
  endpoints are `"BAD_REQUEST"`, `"UNAUTHORISED"`, `"FORBIDDEN"`,
  `"NOT_FOUND"`, `"CONFLICT"`, `"GONE"`, `"UNSUPPORTED_MEDIA_TYPE"`,
  `"TOO_MANY_REQUESTS"` and `"INTERNAL_SERVER_ERROR"`. The FX API
  (`Teya.DCC`) spells it `"UNAUTHORIZED"`, so match both.

  Payment endpoints add codes describing why a card was declined, such as
  `"INSUFFICIENT_FUNDS"`, `"CARD_EXPIRED"`, `"BLOCKED_CARD"` and
  `"SUSPECTED_FRAUD"`. Teya adds codes over time, so handle unknown values.

  Token endpoint failures use the OAuth 2.0 error format instead, giving codes
  such as `"invalid_client"` and `"invalid_scope"`.

  `invalid_parameters` lists the request fields the API rejected, when it says
  which. Each entry is a map, usually with `"name"` and `"reason"` keys. The
  FX API (`Teya.DCC`) names the field `"path"` instead. Read them with
  `Map.get/2`, since the API does not promise every entry has either.

  Every failed request returns this struct. When Teya answered, `status` is
  its HTTP status and `code` its error code. A 2xx status means Teya acted
  on the request but its reply, JSON that would not decode, could not be
  read; none of that reply is kept. That rule does not hold when `reason` is
  `{:no_token, _}`: then the status is the token endpoint's.

  `reason` says what went wrong when there was no usable answer, and is
  `nil` otherwise:

  - `{:no_token, cause}` — the library could not get an access token, so
    nothing was sent to Teya and sending again is safe. `cause` is the
    reason the token request failed, or `nil`. If the token endpoint
    answered, `status` and `code` are its answer, such as 401 and
    `"invalid_client"`.
  - an exception, with `status` `nil` — a network error, such as
    `%Req.TransportError{reason: :timeout}`. You cannot tell whether Teya
    acted on the request, so check before sending a payment again with a new
    idempotency key.
  - an atom or tuple, with `status` `nil` — a failure a function documents,
    such as `:timeout` from `Teya.POSLink.Payment.get/2` or `{:crashed,
    name}` from a POSLink stream whose task crashed.

      case Teya.Checkout.create_session(params) do
        {:ok, session} -> session
        {:error, %Teya.Error{reason: {:no_token, _cause}} = error} -> {:not_sent, error}
        {:error, %Teya.Error{status: nil, reason: reason}} -> {:no_answer, reason}
        {:error, %Teya.Error{status: status}} -> {:refused, status}
      end
  """

  @type t :: %__MODULE__{
          code: String.t() | nil,
          message: String.t() | nil,
          status: integer() | nil,
          invalid_parameters: [map()] | nil,
          reason: term()
        }

  defstruct [:code, :message, :status, :invalid_parameters, :reason]

  @doc false
  # For a failure with no answer from Teya: a network error, say. `context`
  # says what failed. The exceptions kept whole say what went wrong and hold
  # nothing that was received. Any other may, as Req.DecompressError keeps
  # the body, so only its name is kept. So may a Req.HTTPError whose reason
  # is more than a word, such as {:unexpected_data, bytes}.
  @kept_exceptions [Req.TransportError, ReqServerSentEvents.FrameTooLargeError]

  def from_reason(%module{} = exception, context)
      when is_exception(exception) and module in @kept_exceptions,
      do: kept(exception, context)

  def from_reason(%Req.HTTPError{reason: reason} = exception, context) when is_atom(reason),
    do: kept(exception, context)

  def from_reason(%module{} = exception, context) when is_exception(exception),
    do: %__MODULE__{message: context, reason: module}

  def from_reason(reason, context), do: %__MODULE__{message: context, reason: reason}

  defp kept(exception, context),
    do: %__MODULE__{message: context <> ": " <> Exception.message(exception), reason: exception}

  @doc false
  # Teya answered, but in JSON that will not decode. None of the body is
  # kept: it could hold a card number or a credential.
  def unreadable(%{status: status}),
    do: %__MODULE__{status: status, message: "the reply could not be read"}

  @doc false
  # A Teya error names a code; the description and the list of rejected fields
  # are each there only sometimes.
  def from_response(%{status: status, body: %{"code" => code} = body})
      when is_binary(code) or is_integer(code) do
    %__MODULE__{
      # A gateway in front may number its codes; code is text either way.
      code: to_string(code),
      # Teya names it "description". A gateway in front may say "message".
      message: text(body["description"]) || text(body["message"]),
      status: status,
      invalid_parameters: invalid_parameters(body)
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

  # The FX API calls the list "invalid_params". A filled list under either
  # name wins over an empty one or something else under the other, so one
  # cannot hide the other. Keep only what the docs promise, a list of maps.
  defp invalid_parameters(body) do
    lists = Enum.filter([body["invalid_parameters"], body["invalid_params"]], &is_list/1)

    case Enum.find(lists, &(&1 != [])) || List.first(lists) do
      nil -> nil
      params -> Enum.filter(params, &is_map/1)
    end
  end

  @doc false
  # The token endpoint answers in the OAuth 2.0 error format: an "error" code,
  # sometimes with an "error_description". OAuth codes are single words, such
  # as "invalid_client" or, with a 503, "temporarily_unavailable". A rate limiter or firewall may send
  # {"error": "Too Many Requests"} instead; that is a message, not a code a
  # caller could match on, so it is kept as one.
  #
  # A body that also names a Teya "code" is read as a Teya error, which keeps
  # both that code and its message.
  def from_oauth_response(%{body: %{"code" => code}} = resp)
      when is_binary(code) or is_integer(code),
      do: from_response(resp)

  def from_oauth_response(%{status: status, body: %{"error" => error} = body})
      when is_binary(error) do
    if oauth_code?(error),
      do: %__MODULE__{code: error, message: text(body["error_description"]), status: status},
      else: %__MODULE__{message: error, status: status}
  end

  # Anything else — a proxy's page, or a server echoing the form it was sent,
  # client secret and all — keeps none of its body. A failed refresh is
  # logged, and the body could hold a credential.
  def from_oauth_response(%{status: status}),
    do: %__MODULE__{status: status, message: "the token endpoint refused the request"}

  # One word with no spaces: letters in either case, digits, and the
  # separators "_", "-" and ".". That covers "invalid_client" and
  # "INVALID-CLIENT", and leaves out free text such as "Too Many Requests".
  defp oauth_code?(error), do: String.match?(error, ~r/\A[A-Za-z0-9_.-]+\z/)
end
