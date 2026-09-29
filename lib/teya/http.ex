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

  @started_key {__MODULE__, :started_base_url}

  @doc false
  # The API's base URL as the application resolved it when it started, for
  # a request with a token no set of credentials holds, such as ePOS
  # registration: it then goes where every set's requests go, whatever the
  # config says now. Before the application has started, it is base_url/0.
  def started_base_url, do: recorded_base_url() || base_url()

  @doc false
  # The host recorded at start, or nil. An application that could not
  # resolve one then, from an environment it did not know, has no startup
  # host to keep to.
  def recorded_base_url, do: :persistent_term.get(@started_key, nil)

  @doc false
  def put_started_base_url(nil), do: :persistent_term.erase(@started_key)
  def put_started_base_url(url), do: :persistent_term.put(@started_key, url)

  @doc false
  # The token endpoint: :token_url if set, otherwise the :environment's.
  def token_url, do: url(:token_url)

  @doc false
  # Both URLs from one reading of the config, so they cannot come from two
  # environments. The environment is read first, whether or not a URL is
  # set, so an unknown one always raises.
  def urls do
    defaults = environment()
    %{base_url: pick(:base_url, defaults), token_url: pick(:token_url, defaults)}
  end

  defp url(key), do: Map.fetch!(urls(), key)

  # An empty URL, from an unset environment variable say, counts as not set.
  defp pick(key, defaults) do
    case Application.get_env(:teya, key) do
      url when url in [nil, ""] -> Map.fetch!(defaults, key)
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

  # Strings are copied out of the body, so a value the caller keeps does not
  # keep the whole body alive with it.
  defp decode(resp, on_error) do
    case Jason.decode(resp.body, strings: :copy) do
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
    case Application.fetch_env(:teya, key) do
      {:ok, options} -> options
      :error -> Application.get_env(:teya, :req_options, [])
    end
  end

  @doc false
  # Builds a request of one kind: the caller's `defaults`, then the options
  # configured for that kind (see options/1), then the caller's `forced`
  # options, which config cannot change. The user agent is Req's own option,
  # so it gives way to one configured as an option or a header. The body is
  # never decoded by Req: see decode_json/2.
  def new_request(key, defaults, forced) do
    [user_agent: @user_agent]
    |> Keyword.merge(defaults)
    |> Keyword.merge(options(key))
    |> Keyword.merge(forced)
    |> Keyword.put(:decode_body, false)
    |> Req.new()
  end
end
