defmodule Teya.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/sgerrand/ex_teya"

  def project do
    [
      app: :teya,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      test_coverage: [
        tool: ExCoveralls
      ],

      # Hex
      description: "An Elixir client for the Teya API",
      package: package(),

      # Docs
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Teya.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.lcov": :test
      ]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "Teya",
      extras: ["README.md"],
      source_url: @source_url,
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Online Payments": [
          Teya.Checkout,
          Teya.Transaction,
          Teya.PayByLink,
          Teya.Capture,
          Teya.Refund,
          Teya.Receipt,
          Teya.Token
        ],
        "Payments Gateway": [
          Teya.CardPresent,
          Teya.Reversal
        ],
        "Dynamic Currency Conversion": [
          Teya.DCC
        ],
        "POSLink (Card-Present)": [
          Teya.POSLink.Payment,
          Teya.POSLink.Refund,
          Teya.POSLink.Receipt,
          Teya.POSLink.Store
        ]
      ]
    ]
  end

  defp package do
    [
      files: ~w[lib mix.exs README.md LICENSE],
      licenses: ["BSD-2-Clause"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end
end
