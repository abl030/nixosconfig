# Ratchet for the locally-carried libgvc NULL-deref patch.
#
# We patch gnome-shell's bundled libgvc because update_card() dereferences
# pa_card_info.active_profile unconditionally, and pipewire-pulse can hand it a
# card with zero profiles (so that field is NULL). On epi that killed roughly 2
# of every 8 graphical boots — and worse than a bare crash, because the
# OnFailure unit then sets disable-user-extensions and the session returns with
# the taskbar silently gone.
#
# Upstream is MR !38 against issue #47, open at the time of writing:
#   https://gitlab.gnome.org/GNOME/libgnome-volume-control/-/merge_requests/38
#
# The patch is byte-identical to that MR, so the day nixpkgs ships a gnome-shell
# whose bundled gvc already contains the fix, our copy stops applying. Without
# this check that surfaces as a confusing compile failure deep inside a
# gnome-shell build log, on whichever host happens to rebuild first. With it,
# the nightly `nix flake check` fails by name and says what to delete.
#
# This is the whole notification mechanism — no poller, no token, no extra
# service. It runs every night already.
#
# See docs/wiki/infrastructure/epi-gnome-libgvc-segfault.md.
{pkgs}: let
  patchFile = ../pkgs/gnome-shell-libgvc-null-active-profile.patch;

  # Deliberately reads .src, which overrideAttrs leaves untouched, so this
  # inspects pristine upstream rather than our already-patched build.
  gnomeShellLibgvcPatchApplies =
    pkgs.runCommand "gnome-shell-libgvc-patch-applies" {
      nativeBuildInputs = [pkgs.gnutar pkgs.xz pkgs.gnupatch pkgs.gnugrep];
    } ''
      mkdir -p work && cd work
      tar -xf ${pkgs.gnome-shell.src} --wildcards --strip-components=1 \
        '*/subprojects/gvc/gvc-mixer-control.c'

      target=subprojects/gvc/gvc-mixer-control.c
      if [ ! -f "$target" ]; then
        echo "FAIL: $target is not in the gnome-shell tarball any more." >&2
        echo "The gvc subproject may have been restructured or unbundled." >&2
        echo "Re-derive the patch path before assuming the fix landed." >&2
        exit 1
      fi

      # Stage 1: has upstream added the guard?
      #
      # Test for the GUARD, not for the call. MR !38 keeps
      # `gvc_mixer_card_set_profile (card, info->active_profile->name);` and
      # merely indents it under an if, so grepping for the call matches both
      # the vulnerable and the fixed source and discriminates nothing. Verified
      # the hard way on 2026-09-07.
      if grep -q 'if (info->active_profile != NULL)' "$target"; then
        echo "FAIL: upstream libgvc already guards active_profile." >&2
        echo "" >&2
        echo "This almost certainly means MR !38 (or an equivalent fix) has merged:" >&2
        echo "  https://gitlab.gnome.org/GNOME/libgnome-volume-control/-/merge_requests/38" >&2
        echo "" >&2
        echo "Action: drop our local patch. Delete all three of:" >&2
        echo "  1. nix/pkgs/gnome-shell-libgvc-null-active-profile.patch" >&2
        echo "  2. the gnome-shell overlay block in nix/overlay.nix" >&2
        echo "  3. this check (nix/checks/gnome-shell-libgvc.nix) and its" >&2
        echo "     import in nix/checks/default.nix" >&2
        echo "" >&2
        echo "Then confirm epi survives a few reboots without the segfault." >&2
        exit 1
      fi

      # Stage 2: does our patch still apply cleanly on top?
      # --batch --forward so an already-applied patch exits non-zero instead of
      # prompting "Assume -R?" and hanging on a closed stdin.
      if ! ${pkgs.gnupatch}/bin/patch -p1 --dry-run --batch --forward \
             < ${patchFile} > patchlog 2>&1; then
        echo "FAIL: our libgvc patch no longer applies cleanly." >&2
        echo "" >&2
        echo "Upstream still lacks the guard (stage 1 passed), so it has changed" >&2
        echo "the surrounding code rather than fixing the bug." >&2
        echo "Re-cut the patch against the current source; do NOT just drop it," >&2
        echo "the crash is probably still live." >&2
        echo "" >&2
        cat patchlog >&2
        exit 1
      fi

      touch $out
    '';
in {
  inherit gnomeShellLibgvcPatchApplies;
}
