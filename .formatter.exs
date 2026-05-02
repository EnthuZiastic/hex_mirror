[
  import_deps: [],
  inputs: [
    ".claude.exs",
    "*.{ex,exs}",
    "priv/*/seeds.exs",
    "priv/*/seeds/**/*.{ex,exs}",
    "{config,lib,test}/**/*.{ex,exs}",
    "priv/scripts/*.{ex,exs,py}",
    "priv/*/migrations/*"
  ],
  subdirectories: [],
  # Override Ecto's permissive formatter rules to enforce consistent parentheses usage.
  # This prevents formatter drift between local (Homebrew/asdf) and CI (Alpine Docker).
  #
  # Ecto's default allows field/2 and field/3 without parens, but when keyword lists
  # are used (e.g., `field :name, :type, default: value`), different Elixir distributions
  # interpret the arity differently, causing CI failures.
  #
  # Solution: Only allow field/1 (virtual fields) without parens.
  # Everything else REQUIRES parentheses for consistency.
  locals_without_parens: [
    # Query
    from: 2,
    # Schema - only allow single-arg (virtual) fields without parens
    field: 1,
    # Timestamps without args is fine
    timestamps: 0,
    timestamps: 1
    # NOTE: belongs_to, has_one, has_many, etc. are NOT listed here,
    # which means they REQUIRE parentheses for all arities.
  ]
]
