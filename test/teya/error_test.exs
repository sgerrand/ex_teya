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

    test "builds error from response without code or description" do
      assert %Teya.Error{code: nil, message: nil, status: 500} =
               Teya.Error.from_response(%{status: 500})
    end
  end
end
