# Upgrade to Kubernetes 1.33

The cluster runs microk8s 1.32, which is out of upstream support, and Envoy
Gateway v1.9 (the planned ingress-nginx replacement) needs 1.33 or newer.
Several components are too old for 1.33 and have to move first, most of
them one minor version at a time. Everything up to step 7 happens on 1.32.

Compatibility research from 2026-10-22. Recheck release notes before each
step; versions move.

## 1. Preparation

- [x] Every Longhorn volume on engine image v1.7.3, old engine images deleted
- [x] Longhorn system backup (`pre-upgrade-v1-7-3-20261022`)
- [x] Renovate held at Longhorn 1.11.x (1.11.3 and 1.13 need k8s 1.34)

## 2. Longhorn 1.7.3 → 1.11.2

One minor per step, engine images upgraded after each one. Check volumes,
the NFS backup target, the recurring backup job and the Velero `bak`
snapshots after every step. Fresh Velero backup before starting.

- [x] 1.8.2: `backup-target` settings move to a `default` BackupTarget
  ([notes](https://longhorn.io/docs/archives/1.8.2/important-notes/))
- [x] 1.9.2
- [x] Migrate every Longhorn CRD to `v1beta2` only in `storedVersions`.
  Already the case after 1.8.2/1.9.2; recheck right before 1.10.
  Mandatory before 1.10; skipping it leaves only a forced downgrade
  ([notes](https://longhorn.io/docs/archives/1.10.2/important-notes/))
- [x] 1.10.2: v1beta1 API removed, settings move to a v1/v2 JSON format.
  Engine images are now `docker.io/longhornio/...`
- [x] 1.11.2. Not 1.11.3 or 1.12.x: those need k8s 1.34

## 3. Smaller components

- [x] CloudNativePG 1.25.1 → 1.26 → 1.27 → 1.28 → 1.29 → 1.30.1 (1.27-1.29 are
  EOL already). In-place instance manager updates are on; the databases
  restarted once, on the first hop
- [x] Velero 1.15.2 → 1.16.2 (chart 10.1.3), plugin-for-aws v1.12.2
- [x] Vault chart 0.28.1 → 0.34.1 (vault-k8s 1.7.6), server pinned to 1.17.2.
  Upgrading the Vault server itself needs the unseal keys
- [x] cert-manager 1.15.5 → 1.16.5 → 1.17.4 → 1.18.6 → 1.19.6 → 1.20.4
  (1.18 changes the `rotationPolicy` default to Always)

## 4. External Secrets 0.10.7 → 2.13.0

- [x] Every ExternalSecret and the ClusterSecretStore on `external-secrets.io/v1`
- [x] One minor at a time, 28 hops. The ESO app syncs with server-side apply.
  At 0.16.2 the old conversion webhook blocked the new CRDs; setting
  `spec.conversion` to `None` by hand on the three CRDs fixed it
- [ ] Later: once every object is stored as v1, drop v1beta1 from the CRDs'
  `status.storedVersions` (needed before ESO removes v1beta1 entirely)

## 5. Argo CD 2.14.2 → 3.4.12

- [x] v3.0.23 → v3.1.16 → v3.2.12 → v3.3.18 → v3.4.12. Label tracking is
  pinned in `argocd-cm`; our own `resource.exclusions` replaces the 3.0
  defaults, so the home-assistant EndpointSlice stays managed.
  `argocd-folder` syncs with server-side apply (needed from 3.3)
- [ ] Later: switch to annotation tracking (remove the pin, then sync every
  app once)

## 6. Calico 3.25.1 → 3.29.3

- [x] Applied microk8s 1.33's manifest (canonical/microk8s branch 1.33,
  `upgrade-scripts/000-switch-to-calico/resources/calico.yaml`) with
  `kubectl apply --server-side --force-conflicts`. Same calico-node settings
  as before. The manifest is also in
  `/var/snap/microk8s/current/args/cni-network/cni.yaml`; the 3.25.1 one is
  saved as `~/cni-3.25.1-backup.yaml` on opti1

## 7. microk8s 1.32 → 1.33

- [ ] First fix the k8s-dqlite write stalls, see below
- [ ] Fresh Velero backup and `sudo microk8s dbctl backup`
- [ ] `sudo snap refresh microk8s --channel=1.33/stable`
- [ ] `sudo microk8s addons repo update core`
- [ ] If kubelite panics with "Missing actuated resource record"
  ([#5057](https://github.com/canonical/microk8s/issues/5057)):
  `sudo snap revert microk8s`

## 8. After 1.33

- [ ] cert-manager 1.21.2
- [ ] Envoy Gateway v1.9 instead of ingress-nginx, Longhorn behind authentik
  OIDC

Out of scope here but due: the immich PostgreSQL 14 cluster reaches end of
life on 2026-11-12.

## k8s-dqlite write stalls (found 2026-10-22)

Lease updates regularly take more than 10s (169 of ~162k since the API
server started), so controllers using leader election keep losing it and
restarting: snapshot-controller over 1000 times, the CNPG operator,
Longhorn's CSI sidecars.

Cause: the SQLite file behind dqlite is ~709 MB (173k pages of 4 KB) but
164k pages are free. The live data is ~35 MB: 3,700 kine rows for 3,006
keys, so compaction works. SQLite never returns free pages without VACUUM,
and dqlite writes the whole file into a snapshot (~150 MB compressed)
every 1,024 commits, i.e. every few minutes. Each snapshot takes about 6s
of writing on the Apacer AS350 (DRAM-less SATA SSD, which also holds every
Longhorn volume). Commits queue behind it. Outside snapshots fsync takes
about 1.2 ms.

Constraints:
- microk8s 1.32 and 1.33 ship k8s-dqlite v1.3.5 (dqlite 1.17 LTS). VACUUM
  needs dqlite 1.18.2+ (microk8s 1.36). `dbctl restore` writes into the
  running DB, so it doesn't shrink anything.
- microk8s 1.34+ ships k8s-dqlite 1.8.x with a reworked write path; that is
  where Canonical fixed this class of problem (canonical/microk8s#5153).

Plan (needs sudo; the API is down for the length of a dqlite restart,
workloads keep running):
- [ ] `sudo microk8s dbctl backup -o /root/dqlite-pre-tuning`
- [ ] Write `/var/snap/microk8s/current/var/kubernetes/backend/tuning.yaml`
  with `snapshot: {threshold: 8192, trailing: 16384}`: a snapshot every
  ~25 minutes instead of every ~3. Never set trailing alone (threshold
  then becomes 0). Costs ~0.5 GB more raft log on disk.
- [ ] `sudo snap restart microk8s.daemon-k8s-dqlite`, then check snapshot
  spacing in the backend dir and that lease updates stay under 10s
- [ ] Optional: Longhorn backupstore poll interval 300s -> 1800s
  (backupvolume updates are ~8% of all writes)
- Later: microk8s 1.34+ for the new write path (needs Longhorn past 1.11.2).

`--cgroups-per-qos=false`, the likely trigger of the 1.32->1.33 kubelite
panic (#5057), is not set in `args/kubelet`.

