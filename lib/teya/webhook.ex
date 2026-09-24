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
  each event once, keyed on its `event` name together with the id the event
  carries — `data.transaction_id` for `payment.succeeded.v1`. The id alone is
  not enough, since one transaction can lead to more than one kind of event,
  and check each new event type for which id it carries before relying on it.
  """

  @typedoc """
  Why a webhook was not accepted.

  - `:missing_body` — there is no body to check: it is `nil`, such as when the
    raw body was not kept for this request, or it is not bytes or a list of
    them
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
    text = tidy_key_text(text)

    key =
      if String.contains?(text, "-----BEGIN"),
        do: from_pem(text),
        else: from_der(base64(text))

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
  @spec verify(iodata() | nil, binary() | nil, key()) :: :ok | {:error, error()}
  def verify(raw_body, signature, key) do
    with {:ok, _body} <- check(raw_body, signature, key), do: :ok
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
  @spec parse(iodata() | nil, binary() | nil, key()) :: {:ok, map()} | {:error, error()}
  def parse(raw_body, signature, key) do
    with {:ok, body} <- check(raw_body, signature, key) do
      case Jason.decode(body) do
        {:ok, event} when is_map(event) -> {:ok, event}
        _ -> {:error, :malformed_body}
      end
    end
  end

  # Both public functions check in the same order — key, then body, then
  # signature — so a bad key is reported the same way by each, and a bad key
  # is what gets reported when more than one thing is wrong. Returns the body
  # as one binary, joined once.
  defp check(raw_body, signature, key) do
    with {:ok, key} <- to_key(key),
         {:ok, body} <- check_body(raw_body),
         {:ok, signature} <- decode_signature(signature) do
      if :public_key.verify(body, :sha256, signature, key),
        do: {:ok, body},
        else: {:error, :invalid_signature}
    end
  end

  defp to_key(text) when is_binary(text), do: decode_key(text)
  defp to_key(key), do: read_key(key)

  @min_key_bytes div(2048, 8)

  # A key record built or stored by hand can hold anything, and :public_key
  # raises on fields that are not integers rather than refusing the key. Any
  # two integers also decode as an RSA key, so a key too small to be real is
  # refused here, where it is found at startup, rather than left to turn away
  # every webhook. Teya's keys are 2048 bits.
  defp read_key({:RSAPublicKey, modulus, exponent} = key)
       when is_integer(modulus) and modulus > 0 and is_integer(exponent) and exponent > 1 and
              rem(exponent, 2) == 1 do
    if byte_size(:binary.encode_unsigned(modulus)) >= @min_key_bytes,
      do: {:ok, key},
      else: {:error, :malformed_key}
  end

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

  # Teya sends standard padded Base64. Unpadded or URL-safe text is read as
  # well, since something in between may have changed it; the signature is
  # still checked in full either way.
  defp decode_signature(signature) when is_binary(signature) do
    if String.trim(signature) == "" do
      {:error, :missing_signature}
    else
      with :error <- Base.decode64(signature, ignore: :whitespace, padding: false),
           :error <- Base.url_decode64(signature, ignore: :whitespace, padding: false),
           do: {:error, :malformed_signature}
    end
  end

  defp decode_signature(_signature), do: {:error, :malformed_signature}

  # Keys stored in environment variables and secret stores arrive damaged in
  # a few common ways: wrapped in the quotes they were written with, or with
  # their line breaks written out as \\n or \\r\\n. Undo those. Line breaks
  # flattened to spaces need nothing here, since Base64 is read ignoring
  # whitespace.
  defp tidy_key_text(text) do
    text
    |> String.trim()
    |> String.replace(["\\r\\n", "\\n"], "\n")
    |> unquote_key()
  end

  defp unquote_key(<<quote, rest::binary>> = text) when quote in [?", ?'] do
    if String.ends_with?(rest, <<quote>>),
      do: String.slice(rest, 0..-2//1),
      else: text
  end

  defp unquote_key(text), do: text

  # Read PEM blocks directly rather than through :public_key.pem_decode/1,
  # which needs each line exactly where it expects it. Only public key blocks
  # are read; anything else, such as a certificate, is passed over.
  @pem_block ~r/-----BEGIN ([A-Z ]+)-----(.*?)-----END \1-----/s

  defp from_pem(text) do
    @pem_block
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.find_value(fn
      ["PUBLIC KEY", body] -> rsa_only(spki(base64(body)))
      ["RSA PUBLIC KEY", body] -> pkcs1(base64(body))
      _other_block -> nil
    end)
  end

  # A PUBLIC KEY block can hold any kind of key. Pass over one that is not RSA,
  # such as an EC key, so an RSA key after it is still found.
  defp rsa_only({:RSAPublicKey, _modulus, _exponent} = key), do: key
  defp rsa_only(_other), do: nil

  # The portal shows the SubjectPublicKeyInfo form, the same bytes a PEM
  # wraps. A plain RSA key is accepted too, since some tools hand that out.
  defp from_der(der), do: spki(der) || pkcs1(der)

  # Read as leniently as the signature is: standard or URL-safe, with or
  # without padding.
  defp base64(text) do
    with :error <- Base.decode64(text, ignore: :whitespace, padding: false),
         :error <- Base.url_decode64(text, ignore: :whitespace, padding: false) do
      nil
    else
      {:ok, der} -> der
    end
  end

  defp spki(nil), do: nil

  defp spki(der) do
    attempt(fn -> :public_key.pem_entry_decode({:SubjectPublicKeyInfo, der, :not_encrypted}) end)
  end

  defp pkcs1(nil), do: nil
  defp pkcs1(der), do: attempt(fn -> :public_key.der_decode(:RSAPublicKey, der) end)

  # OTP's DER decoders fail on bytes they cannot read by raising MatchError
  # rather than returning an error. Only that is caught: anything else, such
  # as :public_key being unavailable, surfaces as the fault it is instead of
  # being reported as a bad key.
  defp attempt(decode) do
    decode.()
  rescue
    MatchError -> nil
  end
end
