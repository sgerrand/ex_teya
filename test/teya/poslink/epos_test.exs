defmodule Teya.POSLink.EposTest do
  use Teya.APICase, async: false

  alias Teya.Error
  alias Teya.POSLink.Epos

  @params %{"store_id" => "store-uuid-1", "epos_external_id" => "till-1"}

  describe "register/2" do
    test "registers with the user's token and returns machine credentials" do
      stub_api(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/poslink/v1/epos/register"

        # The user's token, not the library's own.
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer user-jwt"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == @params

        json_response(conn, 200, %{
          "client_id" => "m2m-client",
          "client_secret" => "m2m-secret",
          "scopes" => ["payment_requests", "payment_requests/id"]
        })
      end)

      assert {:ok, %{"client_id" => "m2m-client", "scopes" => ["payment_requests" | _]}} =
               Epos.register(@params, user_token: "user-jwt")
    end

    test "returns Teya.Error when the user cannot access the store" do
      stub_api(fn conn ->
        error_response(conn, 403, "FORBIDDEN", "No access to this store")
      end)

      assert {:error, %Error{code: "FORBIDDEN", status: 403}} =
               Epos.register(@params, user_token: "user-jwt")
    end

    test "raises without the user's token" do
      assert_raise ArgumentError, ~r/:user_token/, fn -> Epos.register(@params) end

      for opts <- [[], [user_token: ""], [user_token: nil]] do
        assert_raise ArgumentError, ~r/:user_token/, fn -> Epos.register(@params, opts) end
      end
    end

    test "registers before there is any auth process to ask" do
      auth_pid = Process.whereis(Teya.Auth)
      Process.unregister(Teya.Auth)

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer user-jwt"]
        json_response(conn, 200, %{"client_id" => "m2m-client"})
      end)

      try do
        assert {:ok, %{"client_id" => "m2m-client"}} =
                 Epos.register(@params, user_token: "user-jwt")
      after
        Process.register(auth_pid, Teya.Auth)
      end
    end
  end
end
