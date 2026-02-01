# NFS Mount Tuning

## Incident: 2026-02-01 03:30 AWST

Unraid's `shfs` (FUSE user-share daemon) segfaulted in `libfuse3.so`, killing `/mnt/user/*` briefly. `nfsd` returned non-standard errno -107 to clients. Doc1's `hard` NFS mount blocked all I/O indefinitely. Container healthchecks (which stat mount paths) timed out, autoheal killed them, and they couldn't restart while the mount was stale.

## Why `hard` (not `soft`)

`soft` returns I/O errors to applications after retries are exhausted. This risks silent write loss and database corruption — a write() appears to succeed but the data never reaches the server. The NFS kernel docs explicitly warn against `soft` for writable mounts.

## Chosen tuning: `hard,softreval,timeo=50,retrans=5`

- **hard** -- writes never silently fail, no corruption risk
- **softreval** -- cached dentry/attr revalidation returns stale cache instead of blocking during outages (kernel 5.6+). Fresh uncached lookups still block.
- **timeo=50** -- 5s retry interval (default 60s), so recovery is fast after brief blips
- **retrans=5** -- first "server not responding" warning at ~25s, then keeps retrying

## Limitations

A truly dead server still blocks uncached operations indefinitely under `hard`. The only options to avoid that are `soft` (dangerous) or external mount-health monitoring with automated lazy remount.
