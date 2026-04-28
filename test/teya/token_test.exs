defmodule Teya.TokenTest do
  use Teya.APICase, async: false

  describe "delete/3" do
    test "deletes a token and returns :ok on 204" do
      stub_api(fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v1/tokens/tok-uuid-1234"
        assert conn.query_string =~ "store_id=store-uuid-5678"

        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert :ok = Teya.Token.delete("tok-uuid-1234", "store-uuid-5678")
    end

    test "returns Teya.Error on 404 token not found" do
      stub_api(fn conn ->
        error_response(conn, 404, "NOT_FOUND", "Token not found")
      end)

      assert {:error, %Teya.Error{status: 404}} =
               Teya.Token.delete("nonexistent-token", "store-uuid-5678")
    end

    test "returns Teya.Error on 400 missing store_id" do
      stub_api(fn conn ->
        error_response(conn, 400, "BAD_REQUEST", "store_id is required")
      end)

      assert {:error, %Teya.Error{code: "BAD_REQUEST", status: 400}} =
               Teya.Token.delete("tok-uuid-1234", "")
    end
  end
end
