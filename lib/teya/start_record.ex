defmodule Teya.StartRecord do
  @moduledoc false

  # Keeps what the application resolved as it started: the names of the sets
  # of credentials it started, and the API's host, for a request with no set,
  # such as ePOS registration. It is the first child of Teya.Supervisor, so:
  #
  # - the settings are recorded before any auth process can take a request;
  # - only the start whose supervisor registered its name records them, since
  #   a supervisor registers its name before it starts any child: a start
  #   that finds the application running, or loses a race to start it,
  #   records nothing;
  # - they are cleared when the tree stops, whether the application is
  #   stopped or a later child failed to start, so nothing from a run, or
  #   from a start that failed, outlives it.

  use GenServer

  @key __MODULE__

  def start_link({sets, base_url}), do: GenServer.start_link(__MODULE__, {sets, base_url})

  @impl true
  def init({sets, base_url}) do
    # So terminate/2 runs when the supervisor stops this process.
    Process.flag(:trap_exit, true)
    record(sets, base_url)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state), do: :persistent_term.erase(@key)

  @doc false
  # What a start resolved, recorded in full, under one key: a host of nil,
  # from an environment it did not know, replaces any host an earlier run
  # left, so a request with no set reports the environment rather than go to
  # that run's host.
  def record(sets, base_url), do: :persistent_term.put(@key, {sets, base_url})

  @doc false
  # The names of the sets of credentials the application started an auth
  # process for, or [] when nothing is recorded.
  def sets, do: elem(read(), 0)

  @doc false
  # The API's host as the application resolved it when it started, or nil
  # when it could not resolve one, or nothing is recorded.
  def base_url, do: elem(read(), 1)

  defp read, do: :persistent_term.get(@key, {[], nil})
end
