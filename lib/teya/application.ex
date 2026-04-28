defmodule Teya.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.fetch_env(:teya, :client_id) do
        {:ok, _} -> [{Teya.Auth, Teya.Config.from_env()}]
        :error -> []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Teya.Supervisor)
  end
end
