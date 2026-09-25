defmodule Teya.TestEnv do
  @moduledoc false

  # Changes a :teya setting for the running test only, and puts the old value
  # back when the test ends. A setting that was not set is removed again
  # rather than set to nil, since nil would be read as a value.

  import ExUnit.Callbacks, only: [on_exit: 1]

  def put(key, value) do
    original = Application.fetch_env(:teya, key)
    Application.put_env(:teya, key, value)
    on_exit(fn -> restore(key, original) end)
  end

  # Adds options to a keyword-list setting, such as :req_options.
  def add(key, extra), do: put(key, Application.get_env(:teya, key, []) ++ extra)

  defp restore(key, {:ok, value}), do: Application.put_env(:teya, key, value)
  defp restore(key, :error), do: Application.delete_env(:teya, key)
end
