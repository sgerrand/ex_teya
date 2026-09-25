defmodule Teya.ClientTest do
  use Teya.APICase, async: false

  alias Teya.TestEnv

  describe "request/3" do
    test "sends a library user-agent" do
      stub_api(fn conn ->
        assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
        assert user_agent == "teya-elixir/#{Application.spec(:teya, :vsn)}"

        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "keeps configured headers and the idempotency key together" do
      TestEnv.add(:req_options, headers: [{"x-trace-id", "abc"}])

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-trace-id") == ["abc"]
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []
        assert Plug.Conn.get_req_header(conn, "user-agent") == [Teya.HTTP.user_agent()]

        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:post, "/v1/test", body: %{})
    end

    test "lets a configured user-agent win" do
      TestEnv.add(:req_options, headers: [{"User-Agent", "acme/1.0"}])

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["acme/1.0"]
        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "accepts configured headers given as a map" do
      TestEnv.add(:req_options, headers: %{"x-trace-id" => "abc", "user-agent" => ["acme/1.0"]})

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-trace-id") == ["abc"]
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["acme/1.0"]

        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "lets a configured user-agent win when named with an atom" do
      TestEnv.add(:req_options, headers: [user_agent: "acme/1.0"])

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["acme/1.0"]
        assert Plug.Conn.get_req_header(conn, "user_agent") == []

        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "ignores an idempotency key set in configured headers" do
      TestEnv.add(:req_options, headers: [{"idempotency-key", "from-config"}])

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["order-42"]
        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} =
               Teya.Client.request(:post, "/v1/test", body: %{}, idempotency_key: "order-42")
    end

    test "lets a user_agent option in :req_options win" do
      TestEnv.add(:req_options, user_agent: "acme/option")

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["acme/option"]
        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "sends no configured idempotency key on a GET" do
      TestEnv.add(:req_options, headers: [{"idempotency-key", "from-config"}])

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "ignores a :token among the options every resource function passes on" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]
        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test", token: "tok_card_1234")
    end

    test "sends its own token even when :req_options sets :auth" do
      TestEnv.add(:req_options, auth: {:bearer, "proxy-token"})

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]
        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "returns error tuple on transport failure" do
      stub_api(fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Teya.Client.request(:get, "/v1/test")
    end
  end
end
