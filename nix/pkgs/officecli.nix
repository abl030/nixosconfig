{
  lib,
  stdenvNoCC,
  fetchurl,
  icu,
  makeWrapper,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "officecli";
  version = "1.0.143";

  src = fetchurl {
    url = "https://github.com/iOfficeAI/OfficeCLI/releases/download/v${finalAttrs.version}/officecli-linux-x64";
    hash = "sha256-ainFmKeJtXySwD5WCQfT8TGkvQoGh4Wx0ziob8MaWKc=";
  };

  dontUnpack = true;

  # This is a .NET single-file bundle: patchelf changes its embedded offsets
  # and corrupts it. Fleet hosts provide the upstream ELF loader via nix-ld.
  nativeBuildInputs = [makeWrapper];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/libexec/officecli"
    makeWrapper "$out/libexec/officecli" "$out/bin/officecli" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [icu]}" \
      --set OFFICECLI_SKIP_UPDATE 1
    runHook postInstall
  '';

  meta = {
    description = "CLI for creating, editing, and analyzing Office documents";
    homepage = "https://github.com/iOfficeAI/OfficeCLI";
    license = lib.licenses.asl20;
    mainProgram = "officecli";
    platforms = ["x86_64-linux"];
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
  };
})
