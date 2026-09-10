{
  stdenv,
  lib,
  fetchurl,
  autoPatchelfHook,
  curl,
  openssl,
}:
assert lib.assertMsg
(stdenv.hostPlatform.system == "x86_64-linux")
"mongodb80 is currently packaged only for x86_64-linux (the UniFi host architecture)";
  stdenv.mkDerivation (finalAttrs: {
    pname = "mongodb-ce";
    version = "8.0.30";
    strictDeps = true;

    # This is the official MongoDB Community Edition Ubuntu 24.04 tarball. It is
    # an already-built vendor binary; autoPatchelfHook fixes only its NixOS ELF
    # interpreter/library references. Never replace this with pkgs.mongodb or a
    # source checkout: the latter is the linker-OOM failure this package removes.
    src = fetchurl {
      url = "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2404-${finalAttrs.version}.tgz";
      hash = "sha256-05HY84YwUmb0gEpAwM4LLLO55847adzGEtmCAY9tZxk=";
    };

    nativeBuildInputs = [autoPatchelfHook];
    buildInputs = [
      curl.dev
      openssl.dev
      (lib.getLib stdenv.cc.cc)
    ];

    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall
      install -Dm 755 bin/mongod -t "$out/bin"
      install -Dm 755 bin/mongos -t "$out/bin"
      runHook postInstall
    '';

    passthru = {
      mongodbSeries = "8.0";
      sourceUrl = "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2404-${finalAttrs.version}.tgz";
      sourceHash = "sha256-05HY84YwUmb0gEpAwM4LLLO55847adzGEtmCAY9tZxk=";
    };

    meta = {
      description = "MongoDB Community Edition 8.0 server (official precompiled binary)";
      homepage = "https://www.mongodb.com/";
      changelog = "https://www.mongodb.com/docs/v8.0/release-notes/8.0/";
      license = lib.licenses.sspl;
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  })
