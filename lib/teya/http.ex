defmodule Teya.HTTP do
  @moduledoc false

  # What every module that makes a request shares.

  @doc false
  # Worked out once, from the running application, and kept. Where the
  # application is not loaded there is no version, and the slash that would
  # stand before it is left off.
  def user_agent do
    case :persistent_term.get({__MODULE__, :user_agent}, nil) do
      nil ->
        agent = String.trim_trailing("teya-elixir/#{Application.spec(:teya, :vsn)}", "/")
        :persistent_term.put({__MODULE__, :user_agent}, agent)
        agent

      agent ->
        agent
    end
  end

  @doc false
  # Request options for one kind of request, falling back to :req_options
  # when none are set for it.
  def options(key) do
    Application.get_env(:teya, key, Application.get_env(:teya, :req_options, []))
  end
end
