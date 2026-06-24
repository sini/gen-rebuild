{ ... }:
{
  flake.tests.smoke = {
    test-true = {
      expr = true;
      expected = true;
    };
  };
}
