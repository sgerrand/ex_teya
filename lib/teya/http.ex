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

  # The environment is read first, whether or not the URL is set, so an
  # unknown one always raises. An empty URL, from an unset environment
  # variable say, counts as not set.
  defp url(key) do
    urls = environment()

    case Application.get_env(:teya, key) do
      url when url in [nil, ""] -> Map.fetch!(urls, key)
      url -> url
    end
  end

  # Takes the name as an atom or as text, as System.get_env/2 gives it.
  defp environment do
    name = Application.get_env(:teya, :environment, :production)

    case Enum.find(@environments, fn {key, _urls} -> name in [key, Atom.to_string(key)] end) do
      {_key, urls} ->
        urls

      nil ->
        names = @environments |> Map.keys() |> Enum.map_join(" or ", &inspect/1)
        raise ArgumentError, "Teya: :environment must be #{names}, got: #{inspect(name)}"
    end
  end

  @doc false
  # Request options for one kind of request, falling back to :req_options
  # when none are set for it.
  def options(key) do
    Application.get_env(:teya, key, Application.get_env(:teya, :req_options, []))
  end
end
