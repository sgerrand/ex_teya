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

  @base_url_key {__MODULE__, :base_url}

  @doc false
  # The API's base URL, as the application resolved it when it started, in
  # the same moment the auth processes read their token URL. Every request
  # uses this, so a change to :environment or :base_url while the
  # application runs cannot send one environment's token to another's API:
  # it takes effect, for both, on the next start.
  def base_url, do: :persistent_term.get(@base_url_key, nil) || configured_base_url()

  @doc false
  # The API's base URL as configured now: :base_url if set, otherwise the
  # :environment's.
  def configured_base_url, do: url(:base_url)

  @doc false
  def put_base_url(url), do: :persistent_term.put(@base_url_key, url)

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
  # Decodes a JSON reply. Callers turn Req's own decoding off, since it turns
  # a body that will not decode into an error that drops the status and
  # holds the whole body, which can carry a credential. Here the status
  # survives, and such a body comes back as :unreadable, for the caller to
  # report without any of it.
  #
  # With `unlabelled: true`, a body that is not labelled as JSON is decoded
  # too when it is valid JSON, and otherwise left as text. A POSLink stream's
  # error body is read that way, since its content type is not always set.
  def decode_json(%Req.Response{body: body} = resp, opts \\ []) do
    # A body still marked as encoded was not decompressed, so it is passed on
    # as it is, as Req itself does.
    decodable? =
      is_binary(body) and body != "" and
        Req.Response.get_header(resp, "content-encoding") == []

    cond do
      not decodable? -> {:ok, resp}
      json?(resp) -> decode(resp, {:unreadable, resp})
      opts[:unlabelled] -> decode(resp, {:ok, resp})
      true -> {:ok, resp}
    end
  end

  defp decode(resp, on_error) do
    case Jason.decode(resp.body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      {:error, _error} -> on_error
    end
  end

  defp json?(resp) do
    resp
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&(&1 |> String.downcase() |> String.contains?("json")))
  end

  @doc false
  # Request options for one kind of request, falling back to :req_options
  # when none are set for it.
  def options(key) do
    Application.get_env(:teya, key, Application.get_env(:teya, :req_options, []))
  end
end
