defmodule Teya.HTTP do
  @moduledoc false

  # What every module that makes a request shares.

  # Fixed when the library is compiled, so it costs nothing per request and
  # cannot pick up a missing version at run time. A build with no version to
  # hand leaves the version off rather than sending "teya-elixir/".
  @version Mix.Project.config()[:version]
  @user_agent if @version, do: "teya-elixir/#{@version}", else: "teya-elixir"

  @doc false
  def user_agent, do: @user_agent

  @doc false
  # Request options for one kind of request, falling back to :req_options
  # when none are set for it.
  def options(key) do
    Application.get_env(:teya, key, Application.get_env(:teya, :req_options, []))
  end
end
