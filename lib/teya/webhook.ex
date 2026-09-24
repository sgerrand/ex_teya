defmodule Teya.Webhook do
  @moduledoc """
  Checks that a webhook really came from Teya.

  Teya signs every webhook with SHA256withRSA (RSASSA-PKCS1-v1_5 with SHA-256)
  and sends the signature, Base64 encoded, in the `x-teya-signature` header.
  The public key comes from the webhook's settings in the Teya Business Portal.

  Check the signature before you trust anything in the body:

      def handle(conn, raw_body) do
        [signature] = Plug.Conn.get_req_header(conn, "x-teya-signature")

        case Teya.Webhook.parse(raw_body, signature, public_key()) do
          {:ok, event} -> handle_event(event)
          {:error, reason} -> reject(reason)
        end
      end

  ## Reading the raw body

  The signature covers the bytes Teya sent, so a body that has been decoded
  and encoded again will not match, even when the JSON means the same thing.
  In a Plug application, keep the raw body while it is being read:

      defmodule MyApp.RawBody do
        def read_body(conn, opts) do
          {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
          {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
        end
      end

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {MyApp.RawBody, :read_body, []}

  ## Keys

  Both the PEM text and the Base64 DER the portal shows are accepted:

      \"\"\"
      -----BEGIN PUBLIC KEY-----
      MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A...
      -----END PUBLIC KEY-----
      \"\"\"

      "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A..."
  """

  @typedoc """
  Why a webhook was not accepted.

  - `:invalid_signature` — the signature does not match the body and key. The
    webhook did not come from Teya, or the body is not the one that was signed
  - `:malformed_signature` — the header is not valid Base64
  - `:malformed_key` — the key is not a public key in PEM or Base64 DER form
  - `:malformed_body` — the body is signed by Teya but is not a JSON object
  """
  @type error :: :invalid_signature | :malformed_signature | :malformed_key | :malformed_body

  @doc """
  Checks a webhook's signature.

  Returns `:ok` when `signature` is Teya's signature over `raw_body`, and
  `{:error, reason}` otherwise. `raw_body` must be the bytes as received.

  ## Examples

      :ok = Teya.Webhook.verify(raw_body, signature, public_key)
  """
  @spec verify(binary(), binary(), binary()) :: :ok | {:error, error()}
  def verify(raw_body, signature, public_key)
      when is_binary(raw_body) and is_binary(signature) and is_binary(public_key) do
    with {:ok, signature} <- decode_signature(signature),
         {:ok, key} <- decode_key(public_key) do
      if :public_key.verify(raw_body, :sha256, signature, key),
        do: :ok,
        else: {:error, :invalid_signature}
    end
  end

  @doc """
  Checks a webhook's signature and decodes the body.

  Returns `{:ok, event}` with the decoded JSON, or `{:error, reason}`. The body
  is decoded only once the signature has been accepted.

  ## Examples

      {:ok, %{"event" => "payment.succeeded.v1", "data" => data}} =
        Teya.Webhook.parse(raw_body, signature, public_key)
  """
  @spec parse(binary(), binary(), binary()) :: {:ok, map()} | {:error, error()}
  def parse(raw_body, signature, public_key) do
    with :ok <- verify(raw_body, signature, public_key) do
      case Jason.decode(raw_body) do
        {:ok, event} when is_map(event) -> {:ok, event}
        _ -> {:error, :malformed_body}
      end
    end
  end

  defp decode_signature(signature) do
    case Base.decode64(signature, ignore: :whitespace) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :malformed_signature}
    end
  end

  defp decode_key(public_key) do
    key =
      if String.contains?(public_key, "-----BEGIN") do
        from_pem(public_key)
      else
        from_base64_der(public_key)
      end

    case key do
      {:RSAPublicKey, _modulus, _exponent} = key -> {:ok, key}
      _ -> {:error, :malformed_key}
    end
  rescue
    # The key decoders raise on anything they cannot make sense of, and every
    # such key is simply a key this cannot verify with.
    _ -> {:error, :malformed_key}
  end

  defp from_pem(public_key) do
    case :public_key.pem_decode(public_key) do
      [entry | _] -> :public_key.pem_entry_decode(entry)
      [] -> nil
    end
  end

  defp from_base64_der(public_key) do
    case Base.decode64(public_key, ignore: :whitespace) do
      {:ok, der} -> from_der(der)
      :error -> nil
    end
  end

  # The portal shows the SubjectPublicKeyInfo form, the same bytes a PEM
  # wraps. A plain RSA key is accepted too, since some tools hand that out.
  defp from_der(der) do
    :public_key.pem_entry_decode({:SubjectPublicKeyInfo, der, :not_encrypted})
  rescue
    _ -> :public_key.der_decode(:RSAPublicKey, der)
  end
end
