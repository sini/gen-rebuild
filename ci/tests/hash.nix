{ lib, ... }:
let
  inherit (import ../../lib/hash.nix { }) hashEq hashMoved;
in
{
  flake.tests."hash" = {
    test-hashEq-equal = {
      expr = hashEq "x" "x";
      expected = true;
    };
    test-hashEq-differ = {
      expr = hashEq "x" "y";
      expected = false;
    };
    test-hashEq-null-left = {
      expr = hashEq null "x";
      expected = false;
    };
    test-hashEq-null-right = {
      expr = hashEq "x" null;
      expected = false;
    };
    test-hashEq-null-both = {
      expr = hashEq null null;
      expected = false;
    }; # null==null is true in Nix; guard forces false
    test-hashMoved-null-both = {
      expr = hashMoved null null;
      expected = true;
    };
    test-hashMoved-equal = {
      expr = hashMoved "x" "x";
      expected = false;
    };
  };
}
