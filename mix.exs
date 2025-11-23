defmodule AvmLs.MixProject do
  use Mix.Project

  @app :avm_ls

  def project do
    [
      app: @app,
      version: "0.1.0",
      elixir: "~> 1.16",

      compilers: Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      atomvm: [
        start: AvmLs,
        flash_offset: 0x250000
      ],

      name: "AtomVM LED Strip walk",
      docs: [
        main: "AvmLs",
        extras: ["README.md", "gleam.md"],
        formatters: ["html"]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:exatomvm, git: "https://github.com/atomvm/ExAtomVM/"},
      # {:gleam_stdlib, "~> 0.40 or ~> 1.0"},
      # {:mix_gleam, "~> 0.6"} ## Use archive install
      # {:gleeunit, "~> 1.0", only: [:dev, :test], runtime: false},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
