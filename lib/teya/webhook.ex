defmodule Teya.Webhook do
  @moduledoc """
  Checks that a webhook really came from Teya.

  Teya signs every webhook with SHA256withRSA (RSASSA-PKCS1-v1_5 with SHA-256)
  and sends the signature, Base64 encoded, in the `x-teya-signature` header.
  The public key comes from the webhook's settings in the Teya Business Portal,
  as PEM text or Base64. Both are accepted.

  Decode the key once, when your application starts, so a bad key is found
  then rather than when the first real webhook is turned away:

      {:ok, key} = Teya.Webhook.decode_key(System.fetch_env!("TEYA_WEBHOOK_KEY"))

  Then check each webhook before you trust anything in it:

      signature = conn |> Plug.Conn.get_req_header("x-teya-signature") |> List.first()

      case Teya.Webhook.parse(conn.assigns[:raw_body], signature, key) do
        {:ok, %{"event" => "payment.succeeded.v1", "data" => data}} -> handle_payment(data)
        {:ok, _other_event} -> :ok
        {:error, reason} -> reject(reason)
      end

  Answer an event you do not handle with a 2xx too. Anything else counts as a
  failed delivery, and Teya sends the event again, up to six times over about
  nine hours.

  ## Reading the raw body

  The signature covers the bytes Teya sent. A body that has been decoded and
  encoded again will not match, even when the JSON means the same thing, so
  keep the raw body while `Plug.Parsers` reads it. This reader keeps it only
  for the webhook's path, so other requests do not carry a second copy:

      defmodule MyApp.RawBody do
        def read_body(%Plug.Conn{request_path: "/webhooks/teya"} = conn, opts) do
          case Plug.Conn.read_body(conn, opts) do
            {:ok, body, conn} -> {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
            other -> other
          end
        end

        def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)
      end

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {MyApp.RawBody, :read_body, []}

  Handing anything else on, such as `{:more, ...}` for a body over the length
  limit, leaves `Plug.Parsers` to answer it as usual.

  Match the path your webhook really has, including any scope it is mounted
  under. If the reader does not run for a request, there is no raw body, and
  `parse/3` answers `{:error, :missing_body}`.

  ## Replayed webhooks

  A signature says Teya sent the body; it does not say when. Anyone who has
  seen a signed webhook can send it again, and it will still verify. Teya
  sends the same event more than once anyway when a delivery fails, so handle
  each event once, keyed on its `event` name together with
  `data.transaction_id`. The transaction id alone is not enough: one
  transaction can lead to more than one kind of event.
  """

  @typedoc """
  Why a webhook was not accepted.

  - `:missing_body` — there is no body to check, such as when the raw body was
    not kept for this request
  - `:missing_signature` — there is no signature, such as when the request has
    no `x-teya-signature` header
  - `:malformed_signature` — the signature is not valid Base64
  - `:invalid_signature` — the signature does not match the body and key. The
    webhook did not come from Teya, or the body is not the one that was signed
  - `:malformed_key` — the key is not an RSA public key in PEM or Base64 form
  - `:malformed_body` — the body is signed by Teya but is not a JSON object
  """
  @type error ::
          :missing_body
          | :missing_signature
          | :malformed_signature
          | :invalid_signature
          | :malformed_key
          | :malformed_body

  @typedoc "A key as the portal shows it, or one `decode_key/1` has already read."
  @type key :: binary() | :public_key.rsa_public_key()

  @doc """
  Reads a public key given as PEM text or Base64.

  Returns `{:ok, key}` to pass to `verify/3` or `parse/3`, or
  `{:error, :malformed_key}`. Doing this once at startup means a bad key is
  found straight away, and the key is not read again for every webhook.

  PEM text may hold other blocks before the key; the first RSA public key
  block is used. A certificate is not read for the key inside it, so pass the
  public key the portal shows. A PEM squashed onto one line with `\\n` or
  `\\r\\n` in place of its line breaks, as it often is in an environment
  variable, is read too, as is Base64 that has lost its padding.
  """
  @spec decode_key(binary()) :: {:ok, :public_key.rsa_public_key()} | {:error, :malformed_key}
  def decode_key(text) when is_binary(text) do
    key =
      if String.contains?(text, "-----BEGIN"),
        do: from_pem(text),
        else: from_base64(text)

    read_key(key)
  end

  def decode_key(_text), do: {:error, :malformed_key}

  @doc """
  Checks a webhook's signature.

  Returns `:ok` when `signature` is Teya's signature over `raw_body`, and
  `{:error, reason}` otherwise. `raw_body` must be the bytes as received.
  `signature` may be `nil`, as when the header is missing. The key is
  checked first, so a bad key is reported as `:malformed_key` whatever the
  signature holds.

  A signature does not show when the webhook was sent; see
  "Replayed webhooks" in the module docs.

  ## Examples

      :ok = Teya.Webhook.verify(raw_body, signature, key)
  """
  @spec verify(binary() | nil, binary() | nil, key()) :: :ok | {:error, error()}
  def verify(raw_body, signature, key) do
    with {:ok, key} <- to_key(key),
         {:ok, raw_body} <- check_body(raw_body),
         {:ok, signature} <- decode_signature(signature) do
      if :public_key.verify(raw_body, :sha256, signature, key),
        do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  @doc """
  Checks a webhook's signature and decodes the body.

  Returns `{:ok, event}` with the decoded JSON, or `{:error, reason}`. The body
  is decoded only once the signature has been accepted.

  A signature does not show when the webhook was sent; see
  "Replayed webhooks" in the module docs.

  ## Examples

      {:ok, %{"event" => "payment.succeeded.v1", "data" => data}} =
        Teya.Webhook.parse(raw_body, signature, key)
  """
  @spec parse(binary() | nil, binary() | nil, key()) :: {:ok, map()} | {:error, error()}
  def parse(raw_body, signature, key) do
    with :ok <- verify(raw_body, signature, key) do
      case Jason.decode(raw_body) do
        {:ok, event} when is_map(event) -> {:ok, event}
        _ -> {:error, :malformed_body}
      end
    end
  end

  defp to_key(text) when is_binary(text), do: decode_key(text)
  defp to_key(key), do: read_key(key)

  # A key record built or stored by hand can hold anything, and :public_key
  # raises on fields that are not integers rather than refusing the key.
  defp read_key({:RSAPublicKey, modulus, exponent} = key)
       when is_integer(modulus) and is_integer(exponent),
       do: {:ok, key}

  defp read_key(_key), do: {:error, :malformed_key}

  defp check_body(raw_body) when is_binary(raw_body), do: {:ok, raw_body}

  # A body reader that gathers chunks may keep them as a list.
  defp check_body(raw_body) when is_list(raw_body) do
    {:ok, IO.iodata_to_binary(raw_body)}
  rescue
    ArgumentError -> {:error, :missing_body}
  end

  defp check_body(_raw_body), do: {:error, :missing_body}

  defp decode_signature(nil), do: {:error, :missing_signature}
  defp decode_signature(""), do: {:error, :missing_signature}

  # Teya sends standard padded Base64. Unpadded or URL-safe text is read as
  # well, since something in between may have changed it; the signature is
  # still checked in full either way.
  defp decode_signature(signature) when is_binary(signature) do
    with :error <- Base.decode64(signature, ignore: :whitespace, padding: false),
         :error <- Base.url_decode64(signature, ignore: :whitespace, padding: false),
         do: {:error, :malformed_signature}
  end

  defp decode_signature(_signature), do: {:error, :malformed_signature}

  defp from_pem(text) do
    text = String.replace(text, ["\\r\\n", "\\n"], "\n")

    case attempt(fn -> :public_key.pem_decode(text) end) do
      entries when is_list(entries) -> Enum.find_value(entries, &public_key_entry/1)
      nil -> nil
    end
  end

  defp public_key_entry(entry) do
    case attempt(fn -> :public_key.pem_entry_decode(entry) end) do
      {:RSAPublicKey, _modulus, _exponent} = key -> key
      _other -> nil
    end
  end

  # The portal shows the SubjectPublicKeyInfo form, the same bytes a PEM
  # wraps. A plain RSA key is accepted too, since some tools hand that out.
  defp from_base64(text) do
    case Base.decode64(text, ignore: :whitespace, padding: false) do
      {:ok, der} ->
        attempt(fn ->
          :public_key.pem_entry_decode({:SubjectPublicKeyInfo, der, :not_encrypted})
        end) ||
          attempt(fn -> :public_key.der_decode(:RSAPublicKey, der) end)

      :error ->
        nil
    end
  end

  # OTP's key decoders fail on input they cannot read by raising, not by
  # returning an error, and the kind of exception depends on how the input is
  # wrong. These are the kinds they raise. ErlangError is broad — it is what
  # any Erlang error without a closer Elixir match becomes, which covers the
  # decoders' own ASN.1 errors — so a bug that shows up as one is reported as
  # a malformed key too. Anything outside these kinds surfaces as a bug.
  defp attempt(decode) do
    decode.()
  rescue
    _error in [ArgumentError, ErlangError, FunctionClauseError, MatchError] -> nil
  end
end
