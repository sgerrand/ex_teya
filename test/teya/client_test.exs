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

      assert {:ok, _} = Teya.Client.idempotent_post("/v1/test", body: %{})
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
               Teya.Client.idempotent_post("/v1/test", body: %{}, idempotency_key: "order-42")
    end

    test "sends no idempotency key on a POST or PATCH" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
        json_response(conn, 200, %{"ok" => true})
      end)

      for method <- [:post, :patch] do
        assert {:ok, _} = Teya.Client.request(method, "/v1/test", body: %{})
      end
    end

    test "raises when given an idempotency key, rather than drop it" do
      for call <- [
            fn -> Teya.Client.request(:post, "/v1/test", idempotency_key: "order-42") end,
            fn ->
              Teya.Client.request_with_token("user-jwt", :post, "/v1/test",
                idempotency_key: "order-42"
              )
            end
          ] do
        assert_raise ArgumentError, ~r/takes no :idempotency_key/, call
      end
    end

    test "idempotent_post/2 makes up a key when given nil or an empty one" do
      stub_api(fn conn ->
        assert [key] = Plug.Conn.get_req_header(conn, "idempotency-key")
        assert key =~ ~r/\A[0-9a-f]{32}\z/
        json_response(conn, 200, %{"ok" => true})
      end)

      for key <- [nil, ""] do
        assert {:ok, _} = Teya.Client.idempotent_post("/v1/test", body: %{}, idempotency_key: key)
      end
    end

    test "idempotent_post/2 raises for a key that is not text" do
      assert_raise ArgumentError, ~r/must be text, got: 42/, fn ->
        Teya.Client.idempotent_post("/v1/test", body: %{}, idempotency_key: 42)
      end
    end

    test "lets a GET, or a write given a nil key, through with no key" do
      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
        json_response(conn, 200, %{"ok" => true})
      end)

      assert {:ok, _} = Teya.Client.request(:get, "/v1/test", idempotency_key: "order-42")
      assert {:ok, _} = Teya.Client.request(:post, "/v1/test", idempotency_key: nil)
    end

    test "ignores options in :req_options that say what the request is" do
      TestEnv.add(:req_options,
        method: :post,
        url: "https://elsewhere.example/v1/other",
        params: [store_id: "from-config"],
        json: %{"from" => "config"}
      )

      stub_api(fn conn ->
        assert conn.method == "DELETE"
        refute conn.host == "elsewhere.example"
        assert conn.request_path == "/v1/tokens/tok-uuid-1234"
        assert conn.query_string == "store_id=store-uuid-5678"
        assert {:ok, "", _conn} = Plug.Conn.read_body(conn)

        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert :ok = Teya.Token.delete("tok-uuid-1234", "store-uuid-5678")
    end

    test "ignores options in :req_options that change how the reply is read" do
      TestEnv.add(:req_options,
        aws_sigv4: [access_key_id: "AKIA", secret_access_key: "secret", service: "s3"],
        compress_body: true,
        http_errors: :raise,
        cache: true
      )

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test_access_token"]
        assert Plug.Conn.get_req_header(conn, "content-encoding") == []
        error_response(conn, 422, "INVALID", "bad request")
      end)

      assert {:error, %Teya.Error{status: 422, code: "INVALID"}} =
               Teya.Client.request(:post, "/v1/test", body: %{"a" => 1})
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

    test "request_with_token/4 takes no empty token" do
      assert_raise FunctionClauseError, fn ->
        Teya.Client.request_with_token("", :get, "/v1/test", [])
      end
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

      assert {:error, %Teya.Error{status: nil, reason: %Req.TransportError{reason: :timeout}}} =
               Teya.Client.request(:get, "/v1/test")
    end

    test "keeps the status but none of a reply whose JSON will not decode" do
      for status <- [200, 409] do
        stub_api(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, ~s({"card_number":"4111111111111111" broken))
        end)

        assert {:error,
                %Teya.Error{status: ^status, message: "the reply could not be read"} = error} =
                 Teya.Client.request(:post, "/v1/test")

        refute inspect(error) =~ "4111"
      end
    end

    test "decodes JSON whatever the case of its content type" do
      stub_api(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "Application/JSON")
        |> Plug.Conn.send_resp(200, ~s({"ok":true}))
      end)

      assert {:ok, %{"ok" => true}} = Teya.Client.request(:get, "/v1/test")
    end

    test "leaves a body still marked as encoded as it is, as Req does" do
      stub_api(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("content-encoding", "x-unknown")
        |> Plug.Conn.send_resp(200, "still encoded")
      end)

      assert {:ok, "still encoded"} = Teya.Client.request(:get, "/v1/test")
    end

    test "leaves a reply that is not JSON as text" do
      stub_api(fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "ok")
      end)

      assert {:ok, "ok"} = Teya.Client.request(:get, "/v1/test")
    end
  end
end
