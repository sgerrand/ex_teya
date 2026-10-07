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

  # Removes a setting for the running test only.
  def delete(key) do
    original = Application.fetch_env(:teya, key)
    Application.delete_env(:teya, key)
    on_exit(fn -> restore(key, original) end)
  end

  # Adds options to a keyword-list setting, such as :req_options.
  def add(key, extra), do: put(key, Application.get_env(:teya, key, []) ++ extra)

  # Puts back what the application recorded when it started once the
  # running test ends, whatever the test records meanwhile.
  def keep_start_record do
    {sets, base_url} = {Teya.StartRecord.sets(), Teya.StartRecord.base_url()}
    on_exit(fn -> Teya.StartRecord.record(sets, base_url) end)
  end

  # Records `sets` as started, as the application does at boot, with the
  # host it recorded, for the running test only.
  def record_started_sets(sets) do
    keep_start_record()
    Teya.StartRecord.record(sets, Teya.StartRecord.base_url())
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:teya, key, value)
  defp restore(key, :error), do: Application.delete_env(:teya, key)
end
