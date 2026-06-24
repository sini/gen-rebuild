{ spike, ... }:
{
  flake.tests.smoke = {
    test-spike-imports = {
      expr = builtins.isAttrs spike;
      expected = true;
    };
  };
}
