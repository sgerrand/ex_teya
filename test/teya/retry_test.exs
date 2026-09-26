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
      fn _params -> Token.delete("tok-1", "s-1") end,
      &POSLink.Epos.register(&1, user_token: "user-jwt")
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
  # tells the test which idempotency key each attempt carried. The stub runs
  # in the test process, so `failure` can change state for the next attempt.
  defp stub_failing_once(failure, header \\ "idempotency-key") do
    test = self()
    attempts = :counters.new(1, [])

    stub_api(fn conn ->
      :counters.add(attempts, 1, 1)
      send(test, {:attempt, Plug.Conn.get_req_header(conn, header)})

      if :counters.get(attempts, 1) == 1,
        do: failure.(conn),
        else: json_response(conn, 200, %{"ok" => true})
    end)
  end

  defp status(code), do: &Plug.Conn.send_resp(&1, code, "")

  defp retry_after(code, value) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", value)
      |> Plug.Conn.send_resp(code, "")
    end
  end

  # Stands in for the HTTP client, for errors Req.Test cannot make: fails
  # the first attempt with the error the test put in :teya_first_error, then
  # answers 200. It runs in the test process, like a Req.Test stub.
  defmodule FirstAttemptFails do
    @moduledoc false

    def run(req) do
      send(self(), {:attempt, []})

      case Process.delete(:teya_first_error) do
        nil -> {req, Req.Response.new(status: 200, body: %{"ok" => true})}
        error -> {req, error}
      end
    end
  end

  defp fail_first_attempt_with(error) do
    Process.put(:teya_first_error, error)

    req_options =
      Application.get_env(:teya, :req_options)
      |> Keyword.delete(:plug)
      |> Keyword.put(:adapter, FirstAttemptFails)

    TestEnv.put(:req_options, req_options)
  end

  defp put_auth_token(token, failure \\ nil) do
    :sys.replace_state(Teya.Auth, fn state ->
      %{
        state
        | token: token,
          failure: failure,
          failed_at: failure && System.monotonic_time(:millisecond)
      }
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

    test "retries the statuses Req's :transient retries, and no others" do
      for code <- [408, 429, 500, 502, 503, 504] do
        stub_failing_once(status(code))

        assert {:ok, _} = Checkout.create_session(%{}), "#{code} was not retried"
        assert length(attempts()) == 2
      end

      for code <- [501, 505] do
        stub_failing_once(status(code))

        assert {:error, %Teya.Error{status: ^code}} = Checkout.create_session(%{})
        assert length(attempts()) == 1
      end
    end

    test "retries a timeout, a refused or a closed connection, and no other network error" do
      for reason <- [:timeout, :econnrefused, :closed] do
        stub_failing_once(&Req.Test.transport_error(&1, reason))

        assert {:ok, _} = Checkout.create_session(%{}), "#{reason} was not retried"
        assert length(attempts()) == 2
      end

      stub_failing_once(&Req.Test.transport_error(&1, :nxdomain))

      assert {:error, %Req.TransportError{reason: :nxdomain}} = Checkout.create_session(%{})
      assert length(attempts()) == 1
    end

    test "retries an HTTP/2 request the server did not handle, and no other HTTP error" do
      for reason <- [:unprocessed, :pool_not_available] do
        fail_first_attempt_with(%Req.HTTPError{protocol: :http2, reason: reason})

        assert {:ok, _} = Checkout.create_session(%{}), "#{reason} was not retried"
        assert length(attempts()) == 2
      end

      fail_first_attempt_with(%Req.HTTPError{protocol: :http1, reason: :invalid_header})

      assert {:error, %Req.HTTPError{reason: :invalid_header}} = Checkout.create_session(%{})
      assert length(attempts()) == 1
    end

    test "waits out a short Retry-After, but not a long or unreadable one" do
      stub_failing_once(retry_after(503, "5"))
      assert {:ok, _} = Checkout.create_session(%{})
      assert length(attempts()) == 2

      for value <- ["3600", "soon"], code <- [429, 503] do
        stub_failing_once(retry_after(code, value))

        assert {:error, %Teya.Error{status: ^code}} = Checkout.create_session(%{})
        assert length(attempts()) == 1, "Retry-After #{value} on #{code} was retried"
      end
    end

    test "sends each retry with the auth process's current token" do
      stub_failing_once(
        fn conn ->
          put_auth_token("rotated-token")
          Plug.Conn.send_resp(conn, 503, "")
        end,
        "authorization"
      )

      assert {:ok, _} = Checkout.create_session(%{})
      assert attempts() == [["Bearer test_access_token"], ["Bearer rotated-token"]]
    end

    test "keeps the token it has when the auth process has none to give" do
      stub_failing_once(
        fn conn ->
          put_auth_token(nil, %Teya.Error{message: "token endpoint down"})
          Plug.Conn.send_resp(conn, 503, "")
        end,
        "authorization"
      )

      assert {:ok, _} = Checkout.create_session(%{})
      assert attempts() == [["Bearer test_access_token"], ["Bearer test_access_token"]]
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

  describe "a GET retried by Req's default" do
    test "is sent with the auth process's current token" do
      stub_failing_once(
        fn conn ->
          put_auth_token("rotated-token")
          Plug.Conn.send_resp(conn, 503, "")
        end,
        "authorization"
      )

      assert {:ok, _} = Checkout.get_session("cs-1")
      assert attempts() == [["Bearer test_access_token"], ["Bearer rotated-token"]]
    end
  end

  describe "a request with a caller's token" do
    # ePOS registration is never retried unless :req_options says so. When it
    # does, a retry must not swap the user's token for the library's own.
    test "is retried with the token it was given" do
      TestEnv.add(:req_options, retry: :transient)

      stub_failing_once(
        fn conn ->
          put_auth_token("rotated-token")
          Plug.Conn.send_resp(conn, 503, "")
        end,
        "authorization"
      )

      assert {:ok, _} = POSLink.Epos.register(%{}, user_token: "user-jwt")
      assert attempts() == [["Bearer user-jwt"], ["Bearer user-jwt"]]
    end
  end
end
