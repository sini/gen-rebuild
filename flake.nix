{
  description = "gen-rebuild: pure-Nix incremental rebuilder core (Mokhov rebuilder dimension)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    gen-graph.url = "github:sini/gen-graph";
    gen-scope.url = "github:sini/gen-scope";
  };
  outputs =
    {
      nixpkgs,
      gen-graph,
      gen-scope,
      ...
    }:
    {
      lib = import ./. {
        lib = nixpkgs.lib;
        graph = import gen-graph { lib = nixpkgs.lib; };
        scope = import gen-scope { lib = nixpkgs.lib; };
      };
      __functor = _: import ./.;
    };
}
