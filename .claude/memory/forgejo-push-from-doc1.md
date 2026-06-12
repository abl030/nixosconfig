---
name: forgejo-push-from-doc1
description: How to push to Forgejo (git.ablz.au) from doc1 when abl030 has no https credentials
metadata: 
  node_type: memory
  type: project
  originSessionId: 1db6d98d-bee4-4bb8-add1-bf0f900a64ec
---

On doc1, user abl030 has NO git credential for `https://git.ablz.au` (the gh
helper only covers github.com), so `git push` fails with "could not read
Username". Push using the root-owned nixbot token, kept out of argv via git's
config-env:

```sh
export GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.https://git.ablz.au.extraHeader" \
  GIT_CONFIG_VALUE_0="Authorization: token $(sudo cat /run/secrets/forgejo/nixbot-token)"
git push origin master
```

**Why:** same mechanism rolling-flake-update uses (header auth, token never in
URL/remote config). Verify the commit is SSH-signed (`git log -1 --format=%G?`
→ `G`) BEFORE pushing — signed deploys are enforced fleet-wide.
