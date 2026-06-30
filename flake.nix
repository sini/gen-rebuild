{
  description = "gen-rebuild: pure-Nix incremental rebuilder core (Mokhov rebuilder dimension)";

  # gen-rebuild is nixpkgs-lib-free: depends only on gen-prelude + gen-graph + gen-scope
  # (all pure, nixpkgs-lib-free). No nixpkgs input.
  inputs = {
    gen-prelude.url = "github:sini/gen-prelude";
    gen-graph.url = "github:sini/gen-graph";
    gen-scope.url = "github:sini/gen-scope";
  };
  outputs =
    {
      gen-prelude,
      gen-graph,
      gen-scope,
      ...
    }:
    {
      lib = import ./. {
        prelude = gen-prelude.lib;
        graph = gen-graph.lib;
        scope = gen-scope.lib;
      };
    };
}
