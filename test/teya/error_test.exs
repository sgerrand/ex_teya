defmodule Teya.ErrorTest do
  use ExUnit.Case, async: true

  describe "from_response/1" do
    test "builds error from response with code and description" do
      response = %{
        status: 400,
        body: %{"code" => "BAD_REQUEST", "description" => "Invalid input"}
      }

      assert %Teya.Error{code: "BAD_REQUEST", message: "Invalid input", status: 400} =
               Teya.Error.from_response(response)
    end

    test "preserves body as message when response shape is unexpected" do
      response = %{status: 503, body: %{"error" => "service_unavailable"}}

      assert %Teya.Error{code: nil, status: 503, message: message} =
               Teya.Error.from_response(response)

      assert message =~ "service_unavailable"
    end

    test "preserves string body as message" do
      response = %{status: 502, body: "Bad Gateway"}

      assert %Teya.Error{code: nil, status: 502, message: ~s("Bad Gateway")} =
               Teya.Error.from_response(response)
    end

    test "builds error from response without body" do
      assert %Teya.Error{code: nil, message: nil, status: 500} =
               Teya.Error.from_response(%{status: 500})
    end
  end
end
