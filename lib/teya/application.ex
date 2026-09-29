defmodule Teya.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    urls = resolve_urls()
    auth_children = auth_children(urls)
    sets = for {name, _set} <- Teya.Config.sets(), do: name

    # Teya.StartRecord comes first: it records these settings before any
    # auth process starts, only if this supervisor wins its name, and clears
    # them when the tree stops or fails to start.
    children = [
      {Teya.StartRecord, {sets, urls && urls.base_url}},
      {Task.Supervisor, name: Teya.TaskSupervisor} | auth_children
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Teya.Supervisor)
  end

  # The environment's URLs, read once for every set and for requests that
  # use no set. An :environment the library does not know is reported where
  # it is used, by the sets of credentials and by a request, not here: an
  # application that makes no requests, such as one that only checks
  # webhooks, starts.
  defp resolve_urls do
    Teya.HTTP.urls()
  rescue
    ArgumentError -> nil
  end

  @doc false
  # An auth process for the top-level credentials, when :client_id is set,
  # and one for each named set under :credentials, all given the same URLs.
  # Each is registered under a name of its own, not in a shared registry, so
  # none depends on another process: one that fails is restarted alone.
  def auth_children(urls \\ nil) do
    top_level = if Application.fetch_env(:teya, :client_id) == :error, do: [], else: [nil]
    names = top_level ++ Keyword.keys(Teya.Config.sets())

    case names do
      [] ->
        []

      names ->
        # With no URLs resolved, resolving them again raises for the unknown
        # environment, which these credentials need.
        urls = urls || Teya.HTTP.urls()
        for name <- names, do: {Teya.Auth, Teya.Config.from_env(name, urls)}
    end
  end
end
