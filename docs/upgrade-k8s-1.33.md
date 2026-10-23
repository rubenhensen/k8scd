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

- [x] First fix the k8s-dqlite write stalls, see below
- [x] Fresh Velero backup (`pre-microk8s-1-33-202610230712`) and
  `sudo microk8s dbctl backup` (`/root/dqlite-pre-1.33-*`)
- [x] `sudo snap refresh microk8s --channel=1.33/stable`: v1.33.13, snap
  revision 9067, done 2026-10-23
- [x] `sudo microk8s addons repo update core`: branch 1.33, ingress-nginx
  v1.13.8
- [x] If kubelite panics with "Missing actuated resource record"
  ([#5057](https://github.com/canonical/microk8s/issues/5057)):
  `sudo snap revert microk8s`. No panic. The message does show up in the log
  without consequences, and kubelite has not restarted since the refresh.
  The dqlite snapshot tuning survived the refresh.
- [x] Argo CD 3.x puts pre-delete finalizers on helm-longhorn, so they are
  now in git as well

## 8. After 1.33

- [x] cert-manager 1.21.2. The chart dropped the unused tokenrequest Role and
  RoleBinding; Argo CD pruned them
- [ ] Envoy Gateway v1.9 instead of ingress-nginx, Longhorn behind authentik
  OIDC
  - [x] Envoy Gateway v1.9.2 next to nginx. Gateway `homelab` in
    `envoy-gateway-system`, Envoy on host ports 10080/10443 (`gateway/`)
  - [x] One app (gatus, s2.rubenhensen.nl) on an HTTPRoute, reusing its
    existing certificate through a ReferenceGrant; test with
    `curl --resolve <host>:10443:192.168.1.204`
  - [x] Longhorn behind authentik OIDC with a SecurityPolicy, client secret
    in Vault at `kv/longhorn-oidc`. Two snags: authentik only picks up a
    new blueprint file at its hourly discovery (or
    `blueprints_discovery.send()` in `ak shell`), and Envoy Gateway does
    not retry a failed OIDC discovery until something changes, so the
    controller needed a restart. While the policy is invalid Envoy answers
    500, so Longhorn stays closed
  - [x] The other apps. Envoy cuts requests off after 15s by default, so the
    routes set `timeouts.request: 0s`. All hosts answer the same through
    Envoy as through nginx; WordPress only redirects on the test port
    because the Host header carries `:10443`
  - [x] Argo CD on `server.insecure`, so both nginx and Envoy talk plain
    HTTP to argocd-server
  - [x] cert-manager `config.gatewayAPI.enabled`
  - [x] Switch over: `microk8s disable ingress`, Envoy on 80/443, and a
    `gatewayHTTPRoute` HTTP-01 solver on the ClusterIssuer. About a minute
    without HTTP(S) on 2026-10-23; node001's tunnel needed no change
  - [ ] Replace the Ingress objects with Certificate resources (the
    ingress-shim Certificates go with their Ingress, and gateway-shim
    can't write to the app namespaces) and drop the nginx annotations

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
workloads keep running). `~/dqlite-tuning.sh` and `~/tuning.yaml` on opti1
do the first three steps: `ssh -t ruben@192.168.1.204 ./dqlite-tuning.sh`
- [x] `sudo microk8s dbctl backup -o /root/dqlite-pre-tuning-<date>`
- [x] Install `backend/tuning.yaml` with
  `snapshot: {threshold: 8192, trailing: 16384}`: a snapshot every ~25
  minutes instead of every ~3. Never set trailing alone (threshold then
  becomes 0). Leaving out the kine intervals keeps their defaults. Costs
  ~0.5 GB more raft log on disk.
- [x] `sudo snap restart microk8s.daemon-k8s-dqlite`, then check snapshot
  spacing in the backend dir and that lease updates stay under 10s.
  Measured over the first 40 minutes: snapshots 24.7 minutes apart
  (were ~3), 0 of 9,445 lease updates over 4s, no controller restarts
- [ ] Optional: Longhorn backupstore poll interval 300s -> 1800s
  (backupvolume updates are ~8% of all writes)
- Later: microk8s 1.34+ for the new write path and 1.36 for VACUUM, see
  "On to 1.36" below.

`--cgroups-per-qos=false`, the likely trigger of the 1.32->1.33 kubelite
panic (#5057), is not set in `args/kubelet`.

## On to 1.36

microk8s goes up one minor per refresh. 1.34 brings k8s-dqlite 1.8.x with
the reworked write path, 1.36 brings dqlite 1.18.2, which can VACUUM the
mostly empty database. Before every hop: fresh Velero backup, no
deprecated APIs in use (`apiserver_requested_deprecated_apis` metric
empty), and the Calico manifest of the target version (canonical/microk8s
branch `<version>`, `upgrade-scripts/000-switch-to-calico/resources/calico.yaml`).

### microk8s 1.34
- [ ] Read canonical/microk8s#5568 (LIST stalls with k8s-dqlite on 1.34)
- [ ] Offline backup first: k8s-dqlite 1.8 migrates the schema on first
  start, so 1.33 can't read the database afterwards.
  `microk8s stop; sudo tar -cf /root/backend-1.33.tar /var/snap/microk8s/current/var/kubernetes/backend; microk8s start`
- [ ] `sudo snap refresh microk8s --channel=1.34/stable`, then
  `sudo microk8s addons repo update core` and Calico

### Components for 1.35 and 1.36
- [ ] Longhorn 1.11.2 → 1.12 → 1.13 (one minor at a time, now allowed on
  1.34); lift the Renovate hold
- [ ] Argo CD 3.4 → 3.5 (3.4 is tested up to 1.35)
- [ ] Velero 1.16 → 1.17 → 1.18 (1.17 drops restic, we use kopia)
- [ ] Recheck CNPG, External Secrets, the Vault chart and Envoy Gateway
  against 1.36

### microk8s 1.35 and 1.36
- [ ] `sudo snap refresh microk8s --channel=1.35/stable`, addons repo, Calico
- [ ] `sudo snap refresh microk8s --channel=1.36/stable`, addons repo, Calico

### Shrink the database
- [ ] On dqlite 1.18.2+: offline backup, then a supervised VACUUM (the
  maintainers advise against running it unattended). Expect the file to
  go from ~709 MB to ~35 MB and snapshots to shrink with it

