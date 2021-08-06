defmodule OpentelemetryOban.MixProject do
  use Mix.Project

  def project do
    [
      app: :opentelemetry_oban,
      description: description(),
      version: "1.0.0-rc.2",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      dialyzer: [plt_core_path: if(System.get_env("CI") == "true", do: "_build/#{Mix.env()}")],
      deps: deps(),
      name: "Opentelemetry Oban",
      docs: [
        main: "OpentelemetryOban",
        extras: ["README.md"]
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      source_url: "https://github.com/qdentity/opentelemetry_oban"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: []
    ]
  end

  defp description do
    "Trace Oban events with OpenTelemetry."
  end

  defp package do
    [
      description: "OpenTelemetry tracing for Oban",
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/qdentity/opentelemetry_oban",
        "OpenTelemetry Erlang" => "https://github.com/open-telemetry/opentelemetry-erlang",
        "OpenTelemetry.io" => "https://opentelemetry.io"
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:opentelemetry, "~> 1.0.0-rc"},
      {:oban, github: "qdentity/oban", ref: "fork"},
      {:opentelemetry_telemetry, "~> 1.0.0-beta"},
      {:telemetry, "~> 0.4 or ~> 1.0"},
      {:ex_doc, "~> 0.24", only: [:dev], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false}
    ]
  end
end
