defmodule Teya.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    auth_children =
      case Application.fetch_env(:teya, :client_id) do
        {:ok, _} -> [{Teya.Auth, Teya.Config.from_env()}]
        :error -> []
      end

    children = [{Task.Supervisor, name: Teya.TaskSupervisor}] ++ auth_children

    Supervisor.start_link(children, strategy: :one_for_one, name: Teya.Supervisor)
  end
end
