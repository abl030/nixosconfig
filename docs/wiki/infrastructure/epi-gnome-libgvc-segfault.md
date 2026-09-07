# gnome-shell segfault in libgvc — and why the taskbar vanishes

**Status:** patched locally 2026-09-07 (overlay + ratchet check). Upstream fix
open, unmerged.
**Affects:** any GNOME host here — epi confirmed, framework same exposure.

## The symptom you'll actually notice

Your taskbar is gone. Everything else works.

That is two failures stacked. The real bug is a gnome-shell crash; the missing
taskbar is GNOME's *recovery* from it.

## Recovery, if you just want your desktop back

```bash
gsettings set org.gnome.shell disable-user-extensions false
```

Takes effect immediately, no logout. Extensions go from `INITIALIZED` back to
`ACTIVE`; check with `gnome-extensions info dash-to-panel@jderose9.github.com`.

## Why the taskbar goes

`gnome-shell` segfaults → systemd fires its `OnFailure` unit → that unit sets
`org.gnome.shell disable-user-extensions = true` so you can log back in without
a suspect extension → the shell restarts bare. dash-to-panel *is* your taskbar,
so it disappears. Your extensions were never at fault; the kill switch is
indiscriminate by design, because it cannot tell an extension bug from a crash
in the shell's own C.

**The unit is `org.gnome.Shell-disable-extensions.service`.** Not
`gnome-shell-disable-extensions.service` — journal queries under that name
silently return nothing, which will waste your time.

```bash
journalctl --user -b | grep -i "disable-extensions"
coredumpctl list /nix/store/*/bin/.gnome-shell-wrapped
```

## Root cause

pipewire-pulse can serialize a card to the pulse client before its
`SPA_PARAM_EnumProfile` params have arrived, giving a card with
`n_profiles == 0`. libpulse resolves `pa_card_info.active_profile` by matching
the active profile name against the profiles array, so with no profiles it stays
NULL. libgvc's `update_card()` then did:

```c
gvc_mixer_card_set_profile (card, info->active_profile->name);   /* NULL deref */
```

Evidence, all from this box:

- pipewire logs `card N port 0 profiles inconsistent (0 < M)` **0.5–2.2 ms**
  before each fault. Present in exactly the 2 boots that crashed, absent in the
  other 17 in the journal.
- Kernel: `segfault at 0 ... in libgvc.so[d8f4]` — a literal NULL dereference.
- Disassembly at that offset: `mov 0x30(%r10),%rax; mov (%rax),%rsi` — load
  `info->active_profile`, then dereference it with no NULL test.

**It is not Arc-specific.** The 2026-08-16 crash was the onboard Realtek
ALC1220; only 2026-09-07 was the Arc HDMI. Don't chase the GPU.

**It is not rare.** Roughly 2 of 8 graphical boots (~25%). It only feels
occasional because this box holds long uptimes — a period of frequent reboots
makes it a recurring, session-killing event.

## Our fix

`nix/pkgs/gnome-shell-libgvc-null-active-profile.patch`, applied via a
`gnome-shell` overlay in `nix/overlay.nix`. It is upstream
[MR !38](https://gitlab.gnome.org/GNOME/libgnome-volume-control/-/merge_requests/38)
against [issue #47](https://gitlab.gnome.org/GNOME/libgnome-volume-control/-/issues/47),
byte-identical and deliberately unguarded by version — same convention as the
slskd patch beside it.

The guarded call was always a no-op in the crashing case:
`gvc_mixer_card_set_profile()` opens with
`g_return_val_if_fail (card->priv->profiles != NULL, FALSE)`, and zero profiles
means that list is NULL. The crash happened only because the *argument* is
evaluated before the callee's guard runs.

**Upgrading does not help.** libgvc has no releases — it is a meson `wrap-git`
subproject, expanded into the tarball by `meson dist`. gnome-shell 50.2, 50.4
and main all pin gvc commit `0a4eda0c`, so every version available to us carries
the bug.

## How we find out when to drop the patch

`nix/checks/gnome-shell-libgvc.nix`, run by the nightly `nix flake check`. No
poller, no token, no extra service — it rides machinery that already runs every
night, and a failure feeds the RCA bot, which opens a PR.

Two stages, in order:

1. **Has upstream added the guard?** Greps the pristine `.src` for
   `if (info->active_profile != NULL)`. If present, the fix landed — delete our
   patch, the overlay block, and the check.
2. **Does our patch still apply?** `patch -p1 --dry-run --batch --forward`. If
   this fails while stage 1 passed, upstream changed surrounding code without
   fixing the bug: **re-cut the patch, don't drop it.**

> **Trap, found the hard way:** the obvious stage-1 test — grepping for
> `gvc_mixer_card_set_profile (card, info->active_profile->name);` — does not
> work. MR !38 *keeps* that exact call and merely indents it under the new
> guard, so the string matches both the vulnerable and the fixed source and
> discriminates nothing. Test for the **guard**, never the call.

`--batch --forward` matters too: without it, `patch` meets an already-applied
patch, prompts `Assume -R? [n]`, and behaves unhelpfully on a closed stdin.

## Related, and deliberately not done

- **A dconf self-heal** (`disable-user-extensions = false` as a managed default)
  looks like a free safety net, and is what you'd reach for first. It doesn't
  work here: `home/display_managers/gnome.nix` has its
  `./gnome_configs/${hostname}.nix` import **commented out**, so dconf is not
  managed declaratively at all. Adding the setting to a dormant file achieves
  nothing, and enabling the import would re-apply a large block of stale
  captured dconf — including an `enabled-extensions` list naming two extensions
  that aren't installed. Fixing the crash removes the need for the net.
- Sunshine fails in the crash boots too (`Missing Wayland wire for
  wlr-export-dmabuf` — a wlroots protocol mutter doesn't implement). It begins
  failing *before* the shell dies and is structurally unrelated. Its own
  problem.
