defmodule Teya.ClientTest do
  use Teya.APICase, async: false

  describe "request/3" do
    test "sends a library user-agent" do
      stub_api(fn conn ->
        assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
        assert user_agent == "teya-elixir/#{Application.spec(:teya, :vsn)}"

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
