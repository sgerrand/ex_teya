defmodule Teya.MixProject do
  use Mix.Project

  def project do
    [
      app: :teya,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

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

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "Teya",
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      licenses: ["BSD-2-Clause"],
      links: %{}
    ]
  end
end
