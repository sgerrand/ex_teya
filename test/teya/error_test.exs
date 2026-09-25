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

    test "keeps the invalid parameters the API listed" do
      response = %{
        status: 400,
        body: %{
          "code" => "BAD_REQUEST",
          "description" => "Invalid input",
          "invalid_parameters" => [%{"name" => "amount", "reason" => "must be positive"}]
        }
      }

      assert %Teya.Error{invalid_parameters: [%{"name" => "amount"}]} =
               Teya.Error.from_response(response)
    end

    test "keeps the body as the message for a gateway error carrying an error key" do
      response = %{status: 503, body: %{"error" => "service_unavailable"}}

      assert %Teya.Error{code: nil, status: 503, message: message} =
               Teya.Error.from_response(response)

      assert message =~ "service_unavailable"
    end

    test "preserves body as message when response shape is unexpected" do
      response = %{status: 503, body: %{"detail" => "service unavailable"}}

      assert %Teya.Error{code: nil, status: 503, message: message} =
               Teya.Error.from_response(response)

      assert message =~ "service unavailable"
    end

    test "preserves string body as message" do
      response = %{status: 502, body: "Bad Gateway"}

      assert %Teya.Error{code: nil, status: 502, message: ~s("Bad Gateway")} =
               Teya.Error.from_response(response)
    end

    test "keeps the code and rejected fields when there is no description" do
      response = %{
        status: 400,
        body: %{
          "code" => "BAD_REQUEST",
          "invalid_parameters" => [%{"name" => "amount", "reason" => "must be positive"}]
        }
      }

      assert %Teya.Error{
               code: "BAD_REQUEST",
               message: nil,
               status: 400,
               invalid_parameters: [%{"name" => "amount"}]
             } = Teya.Error.from_response(response)
    end

    test "reads the message from a message field when there is no description" do
      response = %{status: 429, body: %{"code" => "RATE_LIMITED", "message" => "retry in 30s"}}

      assert %Teya.Error{code: "RATE_LIMITED", message: "retry in 30s", status: 429} =
               Teya.Error.from_response(response)
    end

    test "keeps a gateway's bare message as text" do
      response = %{status: 403, body: %{"message" => "Forbidden"}}

      assert %Teya.Error{code: nil, message: "Forbidden", status: 403} =
               Teya.Error.from_response(response)
    end

    test "keeps the message as text or nothing" do
      response = %{status: 400, body: %{"code" => "BAD_REQUEST", "description" => %{"en" => "x"}}}

      assert %Teya.Error{code: "BAD_REQUEST", message: nil} = Teya.Error.from_response(response)
    end

    test "keeps only a list of maps as the rejected fields" do
      not_a_list = %{
        status: 400,
        body: %{"code" => "BAD_REQUEST", "invalid_parameters" => "amount"}
      }

      mixed = %{
        status: 400,
        body: %{"code" => "BAD_REQUEST", "invalid_parameters" => [%{"name" => "a"}, "b", 3]}
      }

      assert %Teya.Error{invalid_parameters: nil} = Teya.Error.from_response(not_a_list)
      assert %Teya.Error{invalid_parameters: [%{"name" => "a"}]} = Teya.Error.from_response(mixed)
    end

    test "builds error from response without body" do
      assert %Teya.Error{code: nil, message: nil, status: 500} =
               Teya.Error.from_response(%{status: 500})
    end
  end

  describe "from_oauth_response/1" do
    test "builds error from an OAuth error body" do
      response = %{
        status: 401,
        body: %{"error" => "invalid_client", "error_description" => "Unknown client"}
      }

      assert %Teya.Error{code: "invalid_client", message: "Unknown client", status: 401} =
               Teya.Error.from_oauth_response(response)
    end

    test "builds error from an OAuth error body without a description" do
      response = %{status: 400, body: %{"error" => "invalid_scope"}}

      assert %Teya.Error{code: "invalid_scope", message: nil, status: 400} =
               Teya.Error.from_oauth_response(response)
    end

    test "keeps a gateway's free-text error on the token endpoint as the message" do
      response = %{status: 503, body: %{"error" => "Service Unavailable"}}

      assert %Teya.Error{code: nil, message: "Service Unavailable", status: 503} =
               Teya.Error.from_oauth_response(response)
    end

    test "keeps a token endpoint reply with neither kind of code as the message" do
      response = %{status: 502, body: "<html>Bad Gateway</html>"}

      assert %Teya.Error{code: nil, status: 502, message: message} =
               Teya.Error.from_oauth_response(response)

      assert message =~ "Bad Gateway"
    end

    test "reads an OAuth code sent with a 5xx" do
      response = %{status: 503, body: %{"error" => "temporarily_unavailable"}}

      assert %Teya.Error{code: "temporarily_unavailable", status: 503} =
               Teya.Error.from_oauth_response(response)
    end

    test "reads a body that names a Teya code as a Teya error" do
      response = %{
        status: 401,
        body: %{
          "error" => "Unauthorized",
          "code" => "UNAUTHORISED",
          "message" => "secret expired"
        }
      }

      assert %Teya.Error{code: "UNAUTHORISED", message: "secret expired", status: 401} =
               Teya.Error.from_oauth_response(response)
    end

    test "reads an OAuth error sent with another 4xx status" do
      for status <- [403, 429] do
        response = %{status: status, body: %{"error" => "slow_down"}}

        assert %Teya.Error{code: "slow_down", status: ^status} =
                 Teya.Error.from_oauth_response(response)
      end
    end

    test "keeps a free-text error as the message, not the code" do
      response = %{status: 429, body: %{"error" => "Too Many Requests"}}

      assert %Teya.Error{code: nil, message: "Too Many Requests", status: 429} =
               Teya.Error.from_oauth_response(response)
    end

    test "falls back to the standard shape for a non-OAuth body" do
      response = %{
        status: 500,
        body: %{"code" => "INTERNAL_SERVER_ERROR", "description" => "Boom"}
      }

      assert %Teya.Error{code: "INTERNAL_SERVER_ERROR", message: "Boom", status: 500} =
               Teya.Error.from_oauth_response(response)
    end
  end
end
