defmodule Teya.Webhook do
  @moduledoc """
  Checks that a webhook really came from Teya.

  Teya signs every webhook with its RSA key, over a SHA-256 hash of the body,
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

  The reader only runs for a body `Plug.Parsers` reads, which is one whose
  content type matches a parser. Teya sends `application/json`, so keep the
  `:json` parser in the list. A request with any other content type never
  reaches the reader and so has no raw body.

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

  Do not key on the signature header. The signature is read leniently —
  with or without padding, standard or URL-safe — so many different strings
  verify as the same signature, and a replayed webhook can carry any of them.
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

  # Teya's keys are 2048 bits. The smallest 2048-bit number is 2^2047. The
  # upper limit is far past any key in use, but stops a key built by hand from
  # making every check slow.
  @min_modulus Integer.pow(2, 2047)
  @max_modulus Integer.pow(2, 16_384)

  # A key record built or stored by hand can hold anything, and :public_key
  # raises on fields that are not integers rather than refusing the key. Any
  # two integers also decode as an RSA key, so a key too small to be real is
  # refused here, where it is found at startup, rather than left to turn away
  # every webhook.
  defp read_key({:RSAPublicKey, modulus, exponent} = key)
       when is_integer(modulus) and modulus >= @min_modulus and modulus < @max_modulus and
              is_integer(exponent) and exponent > 1 and rem(exponent, 2) == 1,
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

  # Teya sends standard padded Base64. Unpadded or URL-safe text is read as
  # well, since something in between may have changed it; the signature is
  # still checked in full either way.
  defp decode_signature(signature) when is_binary(signature) do
    if String.trim(signature) == "" do
      {:error, :missing_signature}
    else
      case base64(signature) do
        nil -> {:error, :malformed_signature}
        decoded -> {:ok, decoded}
      end
    end
  end

  defp decode_signature(_signature), do: {:error, :malformed_signature}

  # Keys stored in environment variables and secret stores arrive damaged in
  # a few common ways: wrapped in the quotes they were written with, or with
  # their line breaks written out as \n, \r\n or \r — sometimes escaped twice,
  # as \\n. Undo those. At any one place the longest match wins, so \r\n is
  # read as one line break and not two. Line breaks flattened to spaces need
  # nothing here, since Base64 is read ignoring whitespace.
  @escaped_line_breaks ["\\\\r\\\\n", "\\\\n", "\\\\r", "\\r\\n", "\\n", "\\r"]

  defp tidy_key_text(text) do
    text
    |> String.trim()
    |> String.replace(@escaped_line_breaks, "\n")
    |> unquote_key()
  end

  defp unquote_key(<<mark, rest::binary>> = text) when mark in [?", ?'] do
    if String.ends_with?(rest, <<mark>>),
      do: binary_part(rest, 0, byte_size(rest) - 1),
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
      ["PUBLIC KEY", body] -> spki(base64(body))
      ["RSA PUBLIC KEY", body] -> pkcs1(base64(body))
      _other_block -> nil
    end)
  end

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

  # A SubjectPublicKeyInfo can hold any kind of key. Read its outer layer as
  # plain ASN.1 and decode the key inside only when the algorithm is plain RSA
  # (rsaEncryption). Anything else is passed over: an EC key, so an RSA key
  # after it is still found, and an RSA-PSS key, which may not be used for the
  # PKCS#1 v1.5 signatures Teya sends. This also steers clear of the
  # certificate-handling code in :public_key, which raises on an algorithm it
  # does not know.
  @rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}

  defp spki(nil), do: nil

  defp spki(der) do
    case attempt(fn -> :public_key.der_decode(:SubjectPublicKeyInfo, der) end) do
      {:SubjectPublicKeyInfo, {:AlgorithmIdentifier, @rsa_encryption, _params}, key_der} ->
        pkcs1(key_der)

      _other ->
        nil
    end
  end

  defp pkcs1(nil), do: nil
  defp pkcs1(der), do: attempt(fn -> :public_key.der_decode(:RSAPublicKey, der) end)

  # :public_key.der_decode/2 fails on bytes it cannot read by raising rather
  # than returning an error: MatchError for most damage, and FunctionClauseError
  # from der_decode itself for some. Each call this wraps is a single
  # der_decode, so these can only come from reading the bytes. Anything else,
  # such as :public_key being unavailable, surfaces as the fault it is.
  defp attempt(decode) do
    decode.()
  rescue
    _error in [MatchError, FunctionClauseError] -> nil
  end
end
