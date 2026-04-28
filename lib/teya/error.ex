defmodule Teya.Error do
  @moduledoc """
  Represents an error returned by the Teya API.

  Pattern-match on `code` for Teya-specific error codes:
  `"BAD_REQUEST"`, `"UNAUTHORISED"`, `"FORBIDDEN"`, `"TOO_MANY_REQUESTS"`,
  `"INTERNAL_SERVER_ERROR"`.
  """

  @type t :: %__MODULE__{
          code: String.t() | nil,
          message: String.t() | nil,
          status: integer() | nil
        }

  defstruct [:code, :message, :status]

  @doc false
  def from_response(%{status: status, body: %{"code" => code, "description" => message}}) do
    %__MODULE__{code: code, message: message, status: status}
  end

  def from_response(%{status: status}) do
    %__MODULE__{status: status}
  end
end
