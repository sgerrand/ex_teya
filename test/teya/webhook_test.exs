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

    test "rejects an empty signature", ctx do
      assert {:error, :invalid_signature} = Webhook.verify(@body, "", ctx.pem)
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
