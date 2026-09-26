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
      fail_auth_until_exit()

      stub_api(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer user-jwt"]
        json_response(conn, 200, %{"client_id" => "m2m-client"})
      end)

      assert {:ok, %{"client_id" => "m2m-client"}} =
               Epos.register(@params, user_token: "user-jwt")
    end
  end

  # Makes the auth process answer every caller with an error, as it would
  # before there are credentials to fetch with, and puts its state back when
  # the test ends. Like APICase's setup, this allows for the process being
  # missing or restarting after a crash left by an earlier test. A new one
  # holds no token and has no stub to fetch one from, so it fails callers
  # too, and there is nothing to put back.
  defp fail_auth_until_exit do
    with pid when is_pid(pid) <- Process.whereis(Teya.Auth),
         {:ok, seeded} <- on_auth(fn -> :sys.get_state(pid) end) do
      on_exit(fn -> put_auth_state(pid, seeded) end)
      put_auth_state(pid, &failing/1)
    end
  end

  defp put_auth_state(pid, state) when is_map(state), do: put_auth_state(pid, fn _ -> state end)
  defp put_auth_state(pid, fun), do: on_auth(fn -> :sys.replace_state(pid, fun) end)

  defp failing(state) do
    %{
      state
      | token: nil,
        usable_until: nil,
        failed_at: System.monotonic_time(:millisecond),
        failure: %Error{message: "no credentials yet"}
    }
  end

  # An exit here means the process died between being looked up and asked.
  defp on_auth(fun) do
    {:ok, fun.()}
  catch
    :exit, _reason -> :gone
  end
end
