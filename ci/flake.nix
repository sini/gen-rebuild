{
  inputs = {
    gen.url = "github:sini/gen";
    gen-prelude.url = "github:sini/gen-prelude";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    gen-graph.url = "github:sini/gen-graph";
    gen-scope.url = "github:sini/gen-scope";
  };

  outputs =
    inputs@{
      gen,
      gen-prelude,
      gen-graph,
      gen-scope,
      ...
    }:
    let
      prelude = import "${gen-prelude}/lib";
      graph = gen-graph.lib;
      scope = gen-scope.lib;
      genRebuild = import ../lib { inherit prelude graph scope; };
    in
    gen.lib.mkCi {
      inherit inputs;
      name = "gen-rebuild";
      testModules = ./tests;
      specialArgs = { inherit genRebuild graph; };
    };
}
