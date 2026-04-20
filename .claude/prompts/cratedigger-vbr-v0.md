# Implement VBR V0 Support in Cratedigger (Red/Green TDD)

## Issue
https://github.com/abl030/cratedigger/issues/1

## Objective
Add `mp3 v0` and `mp3 v2` support to cratedigger's `allowed_filetypes` config so VBR MP3 files can be specifically targeted instead of falling through to the catch-all bare `mp3` entry.

## Repos & Files

**Cratedigger fork** (where the code change goes):
- Local clone: `~/soularr/` (remote: `github:abl030/cratedigger`)
- Main file: `~/soularr/cratedigger.py`
- Key function: `verify_filetype()` at ~line 280
- No existing tests — you'll create `~/soularr/test_cratedigger.py`

**nixosconfig** (where deployment config lives):
- Cratedigger nix module: `modules/nixos/services/cratedigger.nix`
- Flake input `cratedigger-src` pins the fork (line in `flake.nix`)
- Config template with `allowed_filetypes` is in `cratedigger.nix` ~line 129
- Currently set to: `flac 24/192,flac 24/96,flac 24/48,flac 16/44.1,flac,alac,mp3 320,mp3`

## How `verify_filetype()` Works Today

```python
def verify_filetype(file, allowed_filetype):
    # file dict has: filename, bitRate, sampleRate, bitDepth (all from slskd/Soulseek)
    # allowed_filetype is a string like "mp3 320", "flac 24/96", or bare "flac"

    # 1. Match file extension against filetype prefix
    # 2. If filetype has attributes after a space:
    #    - "24/96" format → match bitdepth + samplerate exactly
    #    - "320" format → match bitrate exactly: str(bitrate) == str(selected_bitrate)
    # 3. If bare filetype (no space) → match any file of that extension
```

The problem: `str(bitrate) == str(selected_bitrate)` is exact match only. VBR V0 files report their average bitrate (~230-260kbps), which doesn't match any fixed CBR value.

## What slskd Reports for Files

The `file` dict from slskd API contains:
- `filename`: full path like `@@user\Music\Artist\track.mp3`
- `bitRate`: integer, e.g. `320` for CBR, `245` for VBR V0 average
- `sampleRate`: integer, e.g. `44100`
- `bitDepth`: integer, e.g. `16`
- `isVariableBitRate`: boolean (check if slskd actually exposes this — may need to query the slskd API on doc2 to confirm: `curl -s localhost:5030/api/v0/searches -H 'X-API-Key: <key>'`)

**IMPORTANT**: Before implementing, check what fields slskd actually returns. SSH to doc2 and inspect a real search response to see if `isVariableBitRate` exists. If it does, use it. If not, use heuristic bitrate ranges.

## Implementation Plan (TDD)

### Phase 1: RED — Write Failing Tests

Create `~/soularr/test_cratedigger.py` with pytest. Test `verify_filetype()` in isolation — it's a pure function, no mocking needed.

**Test cases to write:**

```python
# Existing behaviour (must not break)
def test_mp3_cbr_320_exact_match():
    file = {"filename": "track.mp3", "bitRate": 320}
    assert verify_filetype(file, "mp3 320") == True

def test_mp3_cbr_256_exact_match():
    file = {"filename": "track.mp3", "bitRate": 256}
    assert verify_filetype(file, "mp3 256") == True

def test_mp3_cbr_320_no_match_192():
    file = {"filename": "track.mp3", "bitRate": 192}
    assert verify_filetype(file, "mp3 320") == False

def test_bare_mp3_matches_any():
    file = {"filename": "track.mp3", "bitRate": 128}
    assert verify_filetype(file, "mp3") == True

def test_flac_bitdepth_samplerate():
    file = {"filename": "track.flac", "bitDepth": 24, "sampleRate": 96000}
    assert verify_filetype(file, "flac 24/96") == True

def test_flac_bare_matches_any():
    file = {"filename": "track.flac", "bitRate": 800}
    assert verify_filetype(file, "flac") == True

def test_extension_mismatch():
    file = {"filename": "track.flac", "bitRate": 320}
    assert verify_filetype(file, "mp3 320") == False

# NEW: VBR V0 tests (these will FAIL initially)
def test_mp3_v0_matches_vbr_245():
    file = {"filename": "track.mp3", "bitRate": 245}
    assert verify_filetype(file, "mp3 v0") == True

def test_mp3_v0_matches_vbr_230():
    file = {"filename": "track.mp3", "bitRate": 230}
    assert verify_filetype(file, "mp3 v0") == True

def test_mp3_v0_matches_vbr_260():
    file = {"filename": "track.mp3", "bitRate": 260}
    assert verify_filetype(file, "mp3 v0") == True

def test_mp3_v0_rejects_low_bitrate():
    file = {"filename": "track.mp3", "bitRate": 170}
    assert verify_filetype(file, "mp3 v0") == False

def test_mp3_v0_rejects_cbr_320():
    # CBR 320 should match "mp3 320", not "mp3 v0"
    file = {"filename": "track.mp3", "bitRate": 320}
    assert verify_filetype(file, "mp3 v0") == False

def test_mp3_v0_rejects_cbr_192():
    file = {"filename": "track.mp3", "bitRate": 192}
    assert verify_filetype(file, "mp3 v0") == False

def test_mp3_v2_matches_vbr_190():
    file = {"filename": "track.mp3", "bitRate": 190}
    assert verify_filetype(file, "mp3 v2") == True

def test_mp3_v2_matches_vbr_170():
    file = {"filename": "track.mp3", "bitRate": 170}
    assert verify_filetype(file, "mp3 v2") == True

def test_mp3_v2_rejects_low_bitrate():
    file = {"filename": "track.mp3", "bitRate": 120}
    assert verify_filetype(file, "mp3 v2") == False

# If slskd exposes isVariableBitRate, add tests using that field too
def test_mp3_v0_with_vbr_flag():
    file = {"filename": "track.mp3", "bitRate": 245, "isVariableBitRate": True}
    assert verify_filetype(file, "mp3 v0") == True

def test_mp3_v0_cbr_with_vbr_flag_false():
    # A file reporting 245 CBR (weird but possible) should NOT match v0
    # Only relevant if isVariableBitRate is available
    file = {"filename": "track.mp3", "bitRate": 245, "isVariableBitRate": False}
    assert verify_filetype(file, "mp3 v0") == False
```

**Run tests**: `cd ~/soularr && python -m pytest test_cratedigger.py -v`
(You may need `nix-shell -p python3Packages.pytest` or similar)

Confirm the VBR tests fail. Existing tests should pass.

### Phase 2: GREEN — Implement

Modify `verify_filetype()` in `~/soularr/cratedigger.py` to handle `v0` and `v2` as special attribute values.

**VBR V0 spec** (LAME -V 0): average bitrate typically 220-260kbps, targets ~245kbps
**VBR V2 spec** (LAME -V 2): average bitrate typically 170-210kbps, targets ~190kbps

**Known CBR values to exclude**: 128, 160, 192, 224, 256, 320

Logic for the bitrate matching section (~line 312-317):
```python
# If it is a VBR quality preset
if selected_attributes.lower() in ("v0", "v2"):
    if bitrate:
        cbr_values = {128, 160, 192, 224, 256, 320}
        is_vbr = bitrate not in cbr_values
        # Also check isVariableBitRate if available
        if "isVariableBitRate" in file:
            is_vbr = file["isVariableBitRate"]
        if not is_vbr:
            return False
        if selected_attributes.lower() == "v0":
            return 220 <= bitrate <= 280
        elif selected_attributes.lower() == "v2":
            return 170 <= bitrate <= 220
    return False
# If it is a bitrate (existing code)
else:
    ...
```

Run tests again. All should pass (green).

### Phase 3: Deploy & Verify on doc2

1. **Commit to cratedigger fork**:
   ```bash
   cd ~/soularr
   git add cratedigger.py test_cratedigger.py
   git commit -m "feat: add VBR V0/V2 support in allowed_filetypes"
   git push
   ```

2. **Update flake input in nixosconfig**:
   ```bash
   cd ~/nixosconfig
   nix flake update cratedigger-src
   ```

3. **Update `allowed_filetypes` in cratedigger.nix** to use `mp3 v0` instead of bare `mp3`:
   Change: `flac 24/192,flac 24/96,flac 24/48,flac 16/44.1,flac,alac,mp3 320,mp3`
   To: `flac 24/192,flac 24/96,flac 24/48,flac 16/44.1,flac,alac,mp3 v0,mp3 320`

4. **Run quality gate**: `check` (in nixosconfig)

5. **Deploy to doc2**:
   ```bash
   cd ~/nixosconfig
   git add -A && git commit -m "feat(cratedigger): update fork with VBR V0 support, restrict allowed filetypes"
   git push
   ssh doc2 "cd ~/nixosconfig && git pull && sudo nixos-rebuild switch --flake .#doc2 --refresh"
   ```

6. **Verify on doc2**:
   ```bash
   # Check the generated config
   ssh doc2 "sudo cat /var/lib/cratedigger/config.ini | grep allowed_filetypes"

   # Trigger a cratedigger run and watch
   ssh doc2 "sudo systemctl start cratedigger && journalctl -u cratedigger -f"

   # Look for VBR matches vs rejections in logs
   ```

### Phase 4: Integration Test (Optional)

If you want to verify against real slskd data, SSH to doc2 and query the slskd API for a recent search result to see what fields are actually present:
```bash
ssh doc2 'SLSKD_KEY=$(sudo grep SOULARR_SLSKD_API_KEY /var/lib/cratedigger/config.ini | cut -d= -f2 | tr -d " "); curl -s "http://localhost:5030/api/v0/searches" -H "X-API-Key: $SLSKD_KEY" | python3 -m json.tool | head -100'
```

This tells you whether `isVariableBitRate` exists in the response. Adjust the implementation accordingly.

## Boundary Decisions

- VBR V0 range: **220-280 kbps** (conservative, covers real-world LAME V0 output)
- VBR V2 range: **170-220 kbps** (covers LAME V2 output)
- CBR exclusion: files with standard CBR bitrates (128/160/192/224/256/320) are NOT matched by v0/v2 even if in range
- If `isVariableBitRate` field exists in slskd data, prefer it over heuristic
- Keep bare `mp3` as a valid catch-all option (don't break existing behaviour)

## Don't Forget

- Run the existing tests to make sure nothing breaks
- The `get_existing_quality_tier()` function (~line 824) also maps Lidarr quality names to `allowed_filetypes` — check if it needs updating for VBR
- Close the GitHub issue when done: `gh issue close 1 --repo abl030/cratedigger`
