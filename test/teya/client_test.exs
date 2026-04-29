defmodule Teya.ClientTest do
  use Teya.APICase, async: false

  describe "request/3" do
    test "returns error tuple on transport failure" do
      stub_api(fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Teya.Client.request(:get, "/v1/test")
    end
  end
end
