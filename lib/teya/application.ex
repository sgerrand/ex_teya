defmodule Teya.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    auth_children = auth_children()
    Teya.Auth.put_started_sets(for {name, _set} <- Teya.Config.sets(), do: name)

    children = [{Task.Supervisor, name: Teya.TaskSupervisor} | auth_children]

    Supervisor.start_link(children, strategy: :one_for_one, name: Teya.Supervisor)
  end

  @doc false
  # An auth process for the top-level credentials, when :client_id is set,
  # and one for each named set under :credentials. Each is registered under
  # a name of its own, not in a shared registry, so none depends on another
  # process: one that fails is restarted alone.
  def auth_children do
    top_level =
      case Application.fetch_env(:teya, :client_id) do
        {:ok, _} -> [{Teya.Auth, Teya.Config.from_env()}]
        :error -> []
      end

    named = for {name, _set} <- Teya.Config.sets(), do: {Teya.Auth, Teya.Config.from_env(name)}

    top_level ++ named
  end
end
