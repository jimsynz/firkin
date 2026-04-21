defmodule Firkin.MixProject do
  use Mix.Project

  @moduledoc """
  S3-compatible object storage server as a Plug-based Elixir library.
  """
  @version "0.2.0"
  @source_url "https://harton.dev/james/firkin"

  def project do
    [
      aliases: aliases(),
      app: :firkin,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps(),
      description: @moduledoc,
      dialyzer: [plt_add_apps: [:mix, :iex]],
      docs: docs(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets]
    ]
  end

  defp package do
    [
      maintainers: ["James Harton <james@harton.dev>"],
      licenses: ["Apache-2.0"],
      links: %{"Source" => @source_url}
    ]
  end

  defp aliases, do: []

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}"
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.15"},
      {:saxy, "~> 1.6"},
      {:telemetry, "~> 1.3"},
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:ex_aws, "~> 2.6", only: [:test]},
      {:ex_aws_s3, "~> 2.5", only: [:test]},
      {:hackney, "~> 1.9", only: [:test]},
      {:sweet_xml, "~> 0.7", only: [:test]},
      {:jason, "~> 1.0", only: [:dev, :test]},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:earmark, "~> 1.4", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.4", only: [:dev, :test], runtime: false},
      {:igniter, "~> 0.7", only: [:dev, :test]},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false}
    ]
  end
end
