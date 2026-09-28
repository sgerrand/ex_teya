defmodule Teya.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    urls = resolve_urls()
    auth_children = auth_children(urls)
    sets = for {name, _set} <- Teya.Config.sets(), do: name
    previous = {started_sets(), Teya.HTTP.recorded_base_url()}

    # Recorded before the auth processes start, so none can take a request
    # routed by an earlier run's sets, and put back if the start fails, as a
    # start that finds the application already running does.
    record_start(sets, urls && urls.base_url)
    children = [{Task.Supervisor, name: Teya.TaskSupervisor} | auth_children]

    case Supervisor.start_link(children, strategy: :one_for_one, name: Teya.Supervisor) do
      {:ok, _pid} = started ->
        started

      error ->
        {previous_sets, previous_base_url} = previous
        record_start(previous_sets, previous_base_url)
        error
    end
  end

  # Nothing from a run outlives it, so a later start in the same VM cannot
  # route by what an earlier one resolved.
  @impl true
  def stop(_state), do: record_start([], nil)

  @doc false
  # What a start resolved, recorded in full: a host of nil, from an
  # environment it did not know, erases any host an earlier run left, so a
  # request with no set reports the environment rather than go to that run's
  # host.
  def record_start(sets, base_url) do
    Teya.Auth.put_started_sets(sets)
    Teya.HTTP.put_started_base_url(base_url)
  end

  defp started_sets, do: :persistent_term.get({Teya.Auth, :started_sets}, [])

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
