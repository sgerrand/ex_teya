defmodule Teya.ClientTest do
  use Teya.APICase, async: false

  import ExUnit.Callbacks, only: [on_exit: 1]

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
      original = Application.get_env(:teya, :req_options)
      Application.put_env(:teya, :req_options, original ++ [headers: [{"x-trace-id", "abc"}]])
      on_exit(fn -> Application.put_env(:teya, :req_options, original) end)

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-trace-id") == ["abc"]
        assert Plug.Conn.get_req_header(conn, "idempotency-key") != []
        assert Plug.Conn.get_req_header(conn, "user-agent") == [Teya.Client.user_agent()]

        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:post, "/v1/test", body: %{})
    end

    test "lets a configured user-agent win" do
      original = Application.get_env(:teya, :req_options)

      Application.put_env(
        :teya,
        :req_options,
        original ++ [headers: [{"User-Agent", "acme/1.0"}]]
      )

      on_exit(fn -> Application.put_env(:teya, :req_options, original) end)

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["acme/1.0"]
        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "accepts configured headers given as a map" do
      original = Application.get_env(:teya, :req_options)

      Application.put_env(
        :teya,
        :req_options,
        original ++ [headers: %{"x-trace-id" => "abc", "user-agent" => ["acme/1.0"]}]
      )

      on_exit(fn -> Application.put_env(:teya, :req_options, original) end)

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-trace-id") == ["abc"]
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["acme/1.0"]

        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "lets a configured user-agent win when named with an atom" do
      original = Application.get_env(:teya, :req_options)
      Application.put_env(:teya, :req_options, original ++ [headers: [user_agent: "acme/1.0"]])
      on_exit(fn -> Application.put_env(:teya, :req_options, original) end)

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "user-agent") == ["acme/1.0"]
        assert Plug.Conn.get_req_header(conn, "user_agent") == []

        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test")
    end

    test "ignores an idempotency key set in configured headers" do
      original = Application.get_env(:teya, :req_options)

      Application.put_env(
        :teya,
        :req_options,
        original ++ [headers: [{"idempotency-key", "from-config"}]]
      )

      on_exit(fn -> Application.put_env(:teya, :req_options, original) end)

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["order-42"]
        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} =
               Teya.Client.request(:post, "/v1/test", body: %{}, idempotency_key: "order-42")
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
