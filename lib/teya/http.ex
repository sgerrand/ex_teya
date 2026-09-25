defmodule Teya.HTTP do
  @moduledoc false

  # What every module that makes a request shares.

  # Fixed when the library is compiled, so it costs nothing per request.
  @user_agent "teya-elixir/#{Mix.Project.config()[:version]}"

  @doc false
  def user_agent, do: @user_agent

  @doc false
  # Request options for one kind of request, falling back to :req_options
  # when none are set for it.
  def options(key) do
    Application.get_env(:teya, key, Application.get_env(:teya, :req_options, []))
  end
end
