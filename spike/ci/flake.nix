{
  inputs = {
    gen.url = "github:sini/gen";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    gen-graph.url = "github:sini/gen-graph";
    gen-scope.url = "github:sini/gen-scope";
  };
  outputs =
    inputs@{
      gen,
      nixpkgs,
      gen-graph,
      gen-scope,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      graph = import gen-graph { inherit lib; };
      scope = import gen-scope { inherit lib; };
      genRebuild = import ../../. { inherit lib graph scope; };
      spike = import ../. { inherit lib graph genRebuild; };
    in
    gen.lib.mkCi {
      inherit inputs;
      name = "gen-rebuild-v3-spike";
      testModules = ./tests;
      specialArgs = { inherit genRebuild graph spike; };
    };
}
