{
  packageAttr,
  package,
  availableSeries,
}: {
  inherit packageAttr availableSeries;
  package = {
    inherit (package) name version;
    source = toString package.src;
    # Patch paths include the enclosing nixpkgs source hash, so compare bytes.
    patches = map (patch: builtins.hashFile "sha256" patch) package.patches;
  };
}
