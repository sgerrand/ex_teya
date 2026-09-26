defmodule Teya.RetryTest do
  # Which writes are retried when :retry_idempotent_posts is set, checked in
  # one place: only a POST whose spec documents the Idempotency-Key header,
  # and always with the same key.
  use Teya.APICase, async: false

  alias Teya.POSLink

  alias Teya.{
    Capture,
    CardPresent,
    Checkout,
    Moto,
    PayByLink,
    Receipt,
    Refund,
    Reversal,
    TestEnv,
    Token,
    Transaction
  }

  # Every POST whose endpoint's spec documents the Idempotency-Key header.
  defp retried do
    [
      &Checkout.create_session(&1),
      &PayByLink.create(&1),
      &Transaction.create(&1),
      &Capture.create("txn-1", &1),
      &Refund.create(&1),
      &Moto.create(&1),
      &CardPresent.create(&1),
      &POSLink.Payment.create(&1),
      &POSLink.Refund.create(&1)
    ]
  end

  # Writes whose spec documents no such header. Repeating one after a lost
  # response could act twice: a second receipt, say.
  defp not_retried do
    [
      &Receipt.create("txn-1", &1),
      &Reversal.create(&1),
      &POSLink.Receipt.create(&1),
      &PayByLink.update("link-1", &1),
      fn _params -> POSLink.Payment.cancel("pr-1") end,
      fn _params -> POSLink.Store.put_config("s-1", "KEY", "on") end,
      fn _params -> Token.delete("tok-1", "s-1") end
    ]
  end

  # The test config turns retries off for every request. Take that away, and
  # retry at once and quietly, so the tests see what the library asks for.
  setup do
    req_options = Application.get_env(:teya, :req_options, []) |> Keyword.delete(:retry)
    TestEnv.put(:req_options, req_options ++ [retry_delay: fn _ -> 0 end, retry_log_level: false])
    :ok
  end

  # Fails the first attempt with `failure`, answers the rest with 200, and
  # tells the test which idempotency key each attempt carried.
  defp stub_failing_once(failure) do
    test = self()
    attempts = :counters.new(1, [])

    stub_api(fn conn ->
      :counters.add(attempts, 1, 1)
      send(test, {:attempt, Plug.Conn.get_req_header(conn, "idempotency-key")})

      if :counters.get(attempts, 1) == 1,
        do: failure.(conn),
        else: json_response(conn, 200, %{"ok" => true})
    end)
  end

  defp unavailable(conn), do: Plug.Conn.send_resp(conn, 503, "")

  defp attempts do
    receive do
      {:attempt, key} -> [key | attempts()]
    after
      0 -> []
    end
  end

  test "is off by default: an idempotent POST is sent once" do
    stub_failing_once(&unavailable/1)

    assert {:error, %Teya.Error{status: 503}} = Checkout.create_session(%{})
    assert length(attempts()) == 1
  end

  describe "with :retry_idempotent_posts set" do
    setup do
      TestEnv.put(:retry_idempotent_posts, true)
    end

    test "retries each idempotent POST, sending the same key again" do
      for call <- retried() do
        stub_failing_once(&unavailable/1)

        assert {:ok, _} = call.(%{})
        assert [[key], [key]] = attempts()
        assert key != ""
      end
    end

    test "sends a caller's own key on every attempt" do
      stub_failing_once(&unavailable/1)

      assert {:ok, _} = Checkout.create_session(%{}, idempotency_key: "order-1")
      assert attempts() == [["order-1"], ["order-1"]]
    end

    test "retries a network error" do
      stub_failing_once(&Req.Test.transport_error(&1, :timeout))

      assert {:ok, _} = Checkout.create_session(%{})
      assert length(attempts()) == 2
    end

    test "does not retry a request the API refused" do
      stub_failing_once(&error_response(&1, 400, "BAD_REQUEST", "amount is missing"))

      assert {:error, %Teya.Error{status: 400}} = Checkout.create_session(%{})
      assert length(attempts()) == 1
    end

    test "sends every other write once" do
      for call <- not_retried() do
        stub_failing_once(&unavailable/1)

        assert {:error, %Teya.Error{status: 503}} = call.(%{})
        assert length(attempts()) == 1
      end
    end

    test "gives way to a :retry set in :req_options" do
      TestEnv.add(:req_options, retry: false)
      stub_failing_once(&unavailable/1)

      assert {:error, %Teya.Error{status: 503}} = Checkout.create_session(%{})
      assert length(attempts()) == 1
    end
  end
end
