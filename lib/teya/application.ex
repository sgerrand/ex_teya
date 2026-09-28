defmodule Teya.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    auth_children = auth_children()
    sets = for {name, _set} <- Teya.Config.sets(), do: name
    base_url = started_base_url()

    children = [{Task.Supervisor, name: Teya.TaskSupervisor} | auth_children]

    # Kept only once the supervisor, and with it these auth processes, has
    # started. A start that finds the application already running changes
    # nothing, or requests would be routed by settings the running auth
    # processes were not started with.
    with {:ok, _pid} = started <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Teya.Supervisor) do
      Teya.Auth.put_started_sets(sets)
      if base_url, do: Teya.HTTP.put_started_base_url(base_url)
      started
    end
  end

  # An :environment the library does not know is reported where it is used,
  # by the sets of credentials and by a request, not here: an application
  # that makes no requests, such as one that only checks webhooks, starts.
  defp started_base_url do
    Teya.HTTP.base_url()
  rescue
    ArgumentError -> nil
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
