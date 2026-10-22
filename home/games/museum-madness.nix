{pkgs, ...}: let
  museumMadnessArchive = import ./museum-madness-archive.nix pkgs;

  museumMadnessSource = pkgs.stdenvNoCC.mkDerivation {
    pname = "museum-madness-source";
    version = "1994";
    src = museumMadnessArchive;
    nativeBuildInputs = [pkgs.unzip];
    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      install -d "$out"
      unzip -q "$src" -d "$out"
      runHook postInstall
    '';
  };

  museumMadnessConfig = pkgs.writeText "museum-madness-dosbox.conf" ''
    [dosbox]
    machine = svga_s3
    memsize = 16

    [sdl]
    fullscreen = false
    output = opengl
    mapperfile =

    [render]
    aspect = true
    integer_scaling = vertical

    [cpu]
    core = auto
    cpu_cycles = auto

    [mixer]
    nosound = false
    rate = 44100

    [sblaster]
    sbtype = sbpro2
    sbbase = 220
    irq = 7
    dma = 1
  '';

  museumMadnessLauncher = pkgs.writeShellApplication {
    name = "museum-madness";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      set -euo pipefail

      data_root="''${XDG_DATA_HOME:-$HOME/.local/share}/museum-madness"
      game_dir="$data_root/game"
      source_dir="${museumMadnessSource}/MuseumMa"

      mkdir -p "$data_root"
      if [[ ! -f "$game_dir/MUSEUM.COM" ]]; then
        if [[ -e "$game_dir" || -L "$game_dir" ]]; then
          printf 'Museum Madness data directory exists but is incomplete: %s\n' "$game_dir" >&2
          printf 'Remove it and run museum-madness again to re-seed the game.\n' >&2
          exit 1
        fi

        staging_dir=$(mktemp -d "$data_root/.game.XXXXXX")
        cleanup() {
          rm -rf "$staging_dir"
        }
        trap cleanup EXIT
        cp -R --no-preserve=mode,ownership "$source_dir/." "$staging_dir/"
        chmod -R u+rwX,go+rX "$staging_dir"
        mv -T -- "$staging_dir" "$game_dir"
        trap - EXIT
      fi

      exec ${pkgs.dosbox-staging}/bin/dosbox-staging \
        --noprimaryconf \
        --nolocalconf \
        --conf ${museumMadnessConfig} \
        "$game_dir/MUSEUM.COM"
    '';
  };
in {
  home.packages = [
    pkgs.dosbox-staging
    museumMadnessLauncher
  ];

  xdg.desktopEntries.museum-madness = {
    name = "Museum Madness";
    genericName = "DOS adventure game";
    comment = "Play Museum Madness (1994) with DOSBox Staging";
    exec = "museum-madness";
    terminal = false;
    icon = "applications-games";
    categories = ["Game" "AdventureGame"];
  };
}
