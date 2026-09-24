defmodule Teya.WebhookTest do
  use ExUnit.Case, async: true

  alias Teya.Webhook

  @body ~s({"event":"payment.succeeded.v1","data":{"transaction_id":"tr_1"}})

  setup_all do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _v, modulus, exponent, _, _, _, _, _, _, _} = private_key
    public_key = {:RSAPublicKey, modulus, exponent}

    # What the Business Portal shows: the SubjectPublicKeyInfo DER, Base64
    # encoded, which is the same bytes the PEM wraps.
    {:SubjectPublicKeyInfo, der, :not_encrypted} =
      entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)

    pkcs1_der = :public_key.der_encode(:RSAPublicKey, public_key)

    %{
      private_key: private_key,
      base64_der: Base.encode64(der),
      base64_pkcs1_der: Base.encode64(pkcs1_der),
      pem: :public_key.pem_encode([entry])
    }
  end

  defp sign(body, private_key) do
    body |> :public_key.sign(:sha256, private_key) |> Base.encode64()
  end

  describe "verify/3" do
    test "accepts a signature Teya made, with a PEM key", ctx do
      assert :ok = Webhook.verify(@body, sign(@body, ctx.private_key), ctx.pem)
    end

    test "accepts a Base64 DER key", ctx do
      assert :ok = Webhook.verify(@body, sign(@body, ctx.private_key), ctx.base64_der)
    end

    test "accepts a Base64 key in the older RSA form", ctx do
      assert :ok = Webhook.verify(@body, sign(@body, ctx.private_key), ctx.base64_pkcs1_der)
    end

    test "accepts a key with surrounding whitespace", ctx do
      key = "\n  " <> ctx.base64_der <> "  \n"

      assert :ok = Webhook.verify(@body, sign(@body, ctx.private_key), key)
    end

    test "rejects a body changed after signing", ctx do
      signature = sign(@body, ctx.private_key)
      tampered = String.replace(@body, "tr_1", "tr_2")

      assert {:error, :invalid_signature} = Webhook.verify(tampered, signature, ctx.pem)
    end

    test "rejects a body signed by someone else", ctx do
      other_key = :public_key.generate_key({:rsa, 2048, 65_537})

      assert {:error, :invalid_signature} = Webhook.verify(@body, sign(@body, other_key), ctx.pem)
    end

    test "rejects a re-encoded body", ctx do
      signature = sign(@body, ctx.private_key)
      re_encoded = @body |> Jason.decode!() |> Jason.encode!()

      assert re_encoded != @body
      assert {:error, :invalid_signature} = Webhook.verify(re_encoded, signature, ctx.pem)
    end

    test "rejects a signature that is not Base64", ctx do
      assert {:error, :malformed_signature} = Webhook.verify(@body, "not base64!", ctx.pem)
    end

    test "rejects a missing signature", ctx do
      assert {:error, :missing_signature} = Webhook.verify(@body, nil, ctx.pem)
      assert {:error, :missing_signature} = Webhook.parse(@body, nil, ctx.pem)
    end

    test "rejects an empty signature", ctx do
      assert {:error, :missing_signature} = Webhook.verify(@body, "", ctx.pem)
    end

    test "rejects a missing body", ctx do
      signature = sign(@body, ctx.private_key)

      assert {:error, :missing_body} = Webhook.verify(nil, signature, ctx.pem)
      assert {:error, :missing_body} = Webhook.parse(nil, signature, ctx.pem)
    end

    test "accepts a body kept as a list of chunks", ctx do
      [first, second] = [binary_part(@body, 0, 10), binary_part(@body, 10, byte_size(@body) - 10)]

      assert :ok = Webhook.verify([first, second], sign(@body, ctx.private_key), ctx.pem)
    end

    test "rejects a list that is not a body", ctx do
      assert {:error, :missing_body} =
               Webhook.verify([:not, :bytes], sign(@body, ctx.private_key), ctx.pem)
    end

    test "rejects a key record whose fields are not numbers", ctx do
      key = {:RSAPublicKey, nil, "65537"}

      assert {:error, :malformed_key} = Webhook.verify(@body, sign(@body, ctx.private_key), key)
    end

    test "accepts a signature with its padding removed", ctx do
      signature = @body |> sign(ctx.private_key) |> String.trim_trailing("=")

      assert :ok = Webhook.verify(@body, signature, ctx.pem)
    end

    test "accepts a signature in URL-safe Base64", ctx do
      signature = @body |> :public_key.sign(:sha256, ctx.private_key) |> Base.url_encode64()

      assert :ok = Webhook.verify(@body, signature, ctx.pem)
    end

    test "rejects a signature that is not text", ctx do
      assert {:error, :malformed_signature} = Webhook.verify(@body, 12_345, ctx.pem)
    end

    test "reports a bad key before looking at the signature" do
      assert {:error, :malformed_key} = Webhook.verify(@body, "not base64!", "nope!")
      assert {:error, :malformed_key} = Webhook.verify(@body, nil, "nope!")
    end

    test "accepts a key decode_key/1 has already read", ctx do
      {:ok, key} = Webhook.decode_key(ctx.pem)

      assert :ok = Webhook.verify(@body, sign(@body, ctx.private_key), key)
    end

    test "rejects a key that is not Base64", ctx do
      assert {:error, :malformed_key} =
               Webhook.verify(@body, sign(@body, ctx.private_key), "nope!")
    end

    test "rejects Base64 that is not a key", ctx do
      key = Base.encode64("hello there")

      assert {:error, :malformed_key} = Webhook.verify(@body, sign(@body, ctx.private_key), key)
    end

    test "rejects PEM that holds no entry", ctx do
      key = "-----BEGIN"

      assert {:error, :malformed_key} = Webhook.verify(@body, sign(@body, ctx.private_key), key)
    end

    test "rejects an empty PEM block", ctx do
      key = "-----BEGIN PUBLIC KEY-----\n-----END PUBLIC KEY-----\n"

      assert {:error, :malformed_key} = Webhook.verify(@body, sign(@body, ctx.private_key), key)
    end

    test "rejects a private key in place of the public one", ctx do
      pem =
        :public_key.pem_encode([
          :public_key.pem_entry_encode(:RSAPrivateKey, ctx.private_key)
        ])

      assert {:error, :malformed_key} = Webhook.verify(@body, sign(@body, ctx.private_key), pem)
    end
  end

  describe "decode_key/1" do
    test "reads a PEM key and a Base64 key to the same key", ctx do
      assert {:ok, {:RSAPublicKey, _modulus, _exponent} = key} = Webhook.decode_key(ctx.pem)
      assert {:ok, ^key} = Webhook.decode_key(ctx.base64_der)
    end

    test "reads a PEM squashed onto one line with escaped line breaks", ctx do
      one_line = String.replace(ctx.pem, "\n", "\\n")

      assert {:ok, {:RSAPublicKey, _modulus, _exponent}} = Webhook.decode_key(one_line)
    end

    test "reads a PEM squashed onto one line with escaped Windows line breaks", ctx do
      one_line = String.replace(ctx.pem, "\n", "\\r\\n")

      assert {:ok, {:RSAPublicKey, _modulus, _exponent}} = Webhook.decode_key(one_line)
    end

    test "reads a Base64 key that has lost its padding" do
      # A 2048-bit key with the usual exponent encodes without padding, so use
      # a size whose encoding needs it.
      {:RSAPrivateKey, _v, modulus, exponent, _, _, _, _, _, _, _} =
        :public_key.generate_key({:rsa, 1536, 65_537})

      {:SubjectPublicKeyInfo, der, :not_encrypted} =
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {:RSAPublicKey, modulus, exponent})

      padded = Base.encode64(der)
      unpadded = String.trim_trailing(padded, "=")

      assert unpadded != padded
      assert {:ok, {:RSAPublicKey, ^modulus, ^exponent}} = Webhook.decode_key(unpadded)
    end

    test "finds the public key after another PEM block", ctx do
      private =
        :public_key.pem_encode([
          :public_key.pem_entry_encode(:RSAPrivateKey, ctx.private_key)
        ])

      assert {:ok, {:RSAPublicKey, _modulus, _exponent}} =
               Webhook.decode_key(private <> ctx.pem)
    end

    test "rejects text that is not a key" do
      assert {:error, :malformed_key} = Webhook.decode_key("nope!")
    end

    test "rejects a value that is not text" do
      assert {:error, :malformed_key} = Webhook.decode_key(nil)
    end

    test "rejects a truncated PEM" do
      assert {:error, :malformed_key} =
               Webhook.decode_key("-----BEGIN PUBLIC KEY-----\nnot really\n")
    end
  end

  describe "parse/3" do
    test "returns the decoded event", ctx do
      assert {:ok, event} = Webhook.parse(@body, sign(@body, ctx.private_key), ctx.pem)
      assert event["event"] == "payment.succeeded.v1"
      assert event["data"]["transaction_id"] == "tr_1"
    end

    test "does not decode a body it cannot verify", ctx do
      assert {:error, :invalid_signature} = Webhook.parse(@body, "AAAA", ctx.pem)
    end

    test "rejects a signed body that is not a JSON object", ctx do
      body = "[1, 2, 3]"

      assert {:error, :malformed_body} =
               Webhook.parse(body, sign(body, ctx.private_key), ctx.pem)
    end
  end
end
