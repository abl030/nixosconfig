# Container storage migration plan (nvmeprom -> shared virtiofs)

## Goals

- Create a dedicated dataset on the existing ZFS pool `nvmeprom` for container data.
- Expose the dataset to new VMs `doc2` and `igpu2` at `/mnt/docker` via virtiofs.
- Move containers off `doc1` and `igpu` with planned downtime.
- Track virtiofs in OpenTofu state.
  - Note: `igpu2` passthrough is deferred until after `doc2` is verified.
- Golden path: keep container data on the main node and use virtiofs mappings per node.
  When the maintenance node is in use, create its own containers path and point the
  same virtiofs mapping ID at that path for migration.

## Current findings

- Proxmox pool `nvmeprom` is mounted at `/nvmeprom`.
- `/mnt/docker` on `doc1` and `igpu` is `root:root` but the container user is `abl030` (uid 1000, gid 100).
- Proxmox version: `pve-manager/9.1.4`.

## Design decisions

- Dataset: `nvmeprom/containers`
- Mountpoint on Proxmox: `/nvmeprom/containers`
- Virtiofs mapping ID: `containers`
- Guest mountpoint: `/mnt/docker`
- Owner: `abl030:users` (uid 1000, gid 100)
- Migration model: per-node virtiofs path mapping
  - Main node: `/nvmeprom/containers`
  - Maintenance node: create a local path (not necessarily ZFS) and map it to `containers`
  - This enables controlled migration with a final rsync cutover.

## OpenTofu tracking

- Add virtiofs support in the VM resource generation.
- Bump Proxmox provider to a version that supports virtiofs.
- Add `proxmox.virtiofs` for `doc2` and `igpu2` in `hosts.nix` once created.

## Steps (no-exec plan)

### 1) Create the dataset on Proxmox

```
# On prom (root@192.168.1.12)
zfs create -o mountpoint=/nvmeprom/containers nvmeprom/containers
chown 1000:100 /nvmeprom/containers
```

### 2) Create the Proxmox virtiofs mapping

```
# On prom (root@192.168.1.12)
pvesh create /cluster/mapping/dir \
  --id containers \
  --map "node=prom,path=/nvmeprom/containers" \
  --description "Podman containers dataset"
```

Future: when the maintenance node is online, add its mapping:
```
# On prom (root@192.168.1.12)
pvesh set /cluster/mapping/dir/containers \
  --map "node=maintenance-node-name,path=/path/on/that/node"
```

### 3) Create the new VMs

```
# On your workstation
pve new   # create doc2
pve integrate doc2 <ip> <vmid>

# Defer igpu2 until after doc2 is validated
# (passthrough adds risk; handle after doc2 is stable)
pve new   # create igpu2
pve integrate igpu2 <ip> <vmid>
```

### 4) Track virtiofs in OpenTofu for doc2 + igpu2

In `hosts.nix`, add for each new VM:

```
proxmox.virtiofs = {
  mapping = "containers";
  # optional tuning:
  # cache = "always";
  # direct_io = true;
};
```

Run:

```
pve plan
pve apply
```

### 5) Mount in the guests

In each VM's NixOS configuration:

```
fileSystems."/mnt/docker" = {
  device = "containers";
  fsType = "virtiofs";
  options = [ "rw" "relatime" ];
};

systemd.tmpfiles.rules = [
  "d /mnt/docker 0755 abl030 users - -"
];
```

### 6) Downtime migration

- Phase 1 (doc2 only):
  - Stop containers on `doc1`.
  - Rsync data into `/nvmeprom/containers`.
  - Start containers on `doc2`.
- Phase 2 (igpu2 later, after passthrough is sorted):
  - Stop containers on `igpu`.
  - Rsync data into `/nvmeprom/containers`.
  - Start containers on `igpu2`.

Maintenance node migration (golden path):
- Bring maintenance node online and add its `containers` mapping path.
- Stop containers on the main node and rsync data to the maintenance node path.
- Move VM(s) to the maintenance node and start containers there.
- Reverse after maintenance.

Example (choose one direction):

```
# From Proxmox host:
rsync -aHAX --delete root@doc1:/mnt/docker/ /nvmeprom/containers/doc1/
rsync -aHAX --delete root@igpu:/mnt/docker/ /nvmeprom/containers/igpu/
```

Or rsync from each VM directly into the shared mount after it is attached.

### 7) Validation

- Confirm data size/counts match.
- Start a representative container and validate storage access.
- Confirm `podman ps` shows expected containers.

## Rollback

- Keep original `/mnt/docker` data intact on `doc1` and `igpu` until validation is complete.
- If needed, stop containers on new VMs and revert to old hosts.

## Notes

- Virtiofs mapping is a Proxmox cluster object; it must exist before `pve apply`.
- `check` must run before any commit.
