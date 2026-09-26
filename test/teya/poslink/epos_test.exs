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

    test "registers without asking the auth process for a token" do
      # The auth process answers every caller with an error for this test, as
      # it would before there are credentials to fetch with. Its state from
      # setup is put back afterwards, whatever runs next.
      seeded = :sys.get_state(Teya.Auth)
      on_exit(fn -> :sys.replace_state(Teya.Auth, fn _state -> seeded end) end)

      :sys.replace_state(Teya.Auth, fn state ->
        %{
          state
          | token: nil,
            usable_until: nil,
            failed_at: System.monotonic_time(:millisecond),
            failure: %Error{message: "no credentials yet"}
        }
      end)

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer user-jwt"]
        json_response(conn, 200, %{"client_id" => "m2m-client"})
      end)

      assert {:ok, %{"client_id" => "m2m-client"}} =
               Epos.register(@params, user_token: "user-jwt")
    end
  end
end
