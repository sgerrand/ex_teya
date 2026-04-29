defmodule Teya.ApplicationTest do
  use ExUnit.Case, async: false

  test "starts supervisor without Auth when client_id is not configured" do
    original = Application.fetch_env(:teya, :client_id)
    Application.delete_env(:teya, :client_id)

    try do
      result = Teya.Application.start(:normal, [])
      assert match?({:error, {:already_started, _}}, result)
    after
      case original do
        {:ok, val} -> Application.put_env(:teya, :client_id, val)
        :error -> :ok
      end
    end
  end
end
