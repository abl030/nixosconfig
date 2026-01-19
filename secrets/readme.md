# Secrets Management & Host Bootstrapping

This directory manages encrypted secrets using **Sops** and **Age**.

We use a "Bootstrap Paradox" workflow:
1.  Secrets are encrypted against **Host Keys** (machine identity) AND the **Master User Key** (user identity).
2.  On boot, the Host Key decrypts the Master User Key (`id_ed25519`).
3.  The User uses that Master Key to manage the fleet.

## 🚀 How to Add a New Host

When you install NixOS on a new machine, it generates a unique SSH Host Key (`/etc/ssh/ssh_host_ed25519_key`). You must "bless" this key so the new machine can decrypt the secrets (including the Master Identity).

### 1. Get the New Host's Public Key
**Run on the NEW Host:**
```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
# Output example: ssh-ed25519 AAAAC3... root@newhost
```

### 2. Convert to Age Key
**Run on an ADMIN Machine (e.g., Epi):**
Take the output string from Step 1 and pipe it into `ssh-to-age`:
```bash
cat cat /etc/ssh/ssh_host_ed25519_key.pub | nix-shell -p ssh-to-age --run ssh-to-age
# Output: age1...
```

### 3. Update Config
Edit `.sops.yaml` in this directory. Add the **Age Output** (from Step 2) to the list:
```yaml
creation_rules:
  - path_regex: .*
    key_groups:
      - age:
          - age1... # Existing keys...
          - age1... # NEW HOST KEY (e.g. # framework)
```

### 4. Re-Encrypt Everything
Now update the actual encrypted files so they include the new host's permission header.

**Run from the Repository Root:**
```bash
cd secrets

# Re-encrypt all secrets to include the new host
find . -type f \( -name "*.env" -o -name "*.yaml" -o -name "ssh_key_*" \) | while read file; do
    echo "Updating $file for new host..."
    # We use your User Identity (which is already authorized) to perform the update
    sops updatekeys --yes "$file"
done
```

### 5. Deploy
1.  `git add . && git commit -m "chore: add new host keys"`
2.  Push to GitHub.
3.  On the **New Host**: `nixos-rebuild switch --flake .#hostname`

---

## 🛠 Troubleshooting

**"Failed to get the data key"**
If you cannot decrypt secrets manually:
1.  Ensure you have `ssh-to-age` installed.
2.  Ensure your SSH key is loaded or available at `~/.ssh/id_ed25519`.
3.  If using the `dc` alias, verify it is converting your User SSH key to Age correctly.

**Re-encrypting with Root Keyfile**
If you are on a machine without the user key but have root access:
```bash
sudo env SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt sops updatekeys --yes secrets/some-file.env
```
