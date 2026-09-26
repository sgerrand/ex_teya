defmodule Teya.HTTP do
  @moduledoc false

  # What every module that makes a request shares.

  # Fixed when the library is compiled, so it costs nothing per request.
  @user_agent "teya-elixir/#{Mix.Project.config()[:version]}"

  @doc false
  def user_agent, do: @user_agent

  # The URLs Teya's specs give for each environment.
  @environments %{
    production: %{
      base_url: "https://api.teya.com",
      token_url: "https://id.teya.com/oauth/v2/oauth-token"
    },
    staging: %{
      base_url: "https://api.teya.xyz",
      token_url: "https://id.teya.xyz/oauth/v2/oauth-token"
    }
  }

  @doc false
  # The API's base URL: :base_url if set, otherwise the :environment's.
  def base_url, do: url(:base_url)

  @doc false
  # The token endpoint: :token_url if set, otherwise the :environment's.
  def token_url, do: url(:token_url)

  defp url(key), do: Application.get_env(:teya, key) || Map.fetch!(environment(), key)

  defp environment do
    name = Application.get_env(:teya, :environment, :production)

    case Map.fetch(@environments, name) do
      {:ok, urls} ->
        urls

      :error ->
        raise ArgumentError,
              "Teya: :environment must be :production or :staging, got: #{inspect(name)}"
    end
  end

  @doc false
  # Request options for one kind of request, falling back to :req_options
  # when none are set for it.
  def options(key) do
    Application.get_env(:teya, key, Application.get_env(:teya, :req_options, []))
  end
end
