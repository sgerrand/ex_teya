defmodule Teya.POSLink.SubscribeCase do
  @moduledoc false

  # Test case template for POSLink streaming (subscribe) tests.
  #
  # Like Teya.APICase, it pre-seeds a valid token directly into the auth
  # process's state rather than stubbing the token endpoint. This avoids a
  # race condition where a Task spawned by subscribe/2 outlives the test
  # process: if the token is already cached, Auth.token/0 returns immediately
  # without making any HTTP request, so there is no stub lookup that could
  # fail after the test process exits.

  use ExUnit.CaseTemplate

  import Teya.APICase, only: [reset_auth: 1, reset_auth: 2]

  setup do
    if auth_pid = Process.whereis(Teya.Auth), do: reset_auth(auth_pid, "test_access_token")
    :ok
  end

  @doc """
  Stubs the POSLink SSE endpoint with the given handler for the current test process.

  The handler receives `%Plug.Conn{}` and must return it after sending a response.
  """
  def stub_sse(handler) when is_function(handler, 1) do
    Req.Test.stub(Teya.POSLink.Subscriber, handler)
  end

  @doc """
  Clears the cached auth token and stubs the token endpoint with `handler`.

  Use to exercise the token-fetch failure branch of the subscribe helpers. The
  stub is allowed to the auth process, which is where the token request runs.

  Raises if the auth process is not running. Unlike the seeding in `setup`,
  which is a no-op without it, this helper is a precondition: with no auth
  process there is no token fetch to fail, so the calling test would pass
  without ever reaching the branch it claims to cover.
  """
  def stub_auth(handler) when is_function(handler, 1) do
    auth_pid =
      Process.whereis(Teya.Auth) ||
        raise """
        stub_auth/1 requires the Teya.Auth process to be running, but it is not.

        Teya.Application only starts it when :client_id is configured. Check
        that config/test.exs sets it and that no earlier test deleted it.
        """

    Req.Test.stub(Teya.Auth, handler)
    Req.Test.allow(Teya.Auth, self(), auth_pid)

    reset_auth(auth_pid)
  end

  using do
    quote do
      import Teya.POSLink.SubscribeCase
      import Teya.APICase, only: [json_response: 3, error_response: 4]
    end
  end
end
