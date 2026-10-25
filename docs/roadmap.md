# Roadmap

Where the cluster stands and what is left, as of 2026-10-25. Takes over
from wishlist.txt (January 2026, removed); its items are sorted in at the
bottom.

## State

One node: opti1, an OptiPlex 5060 with an i5-8600T, 32 GB and one 1 TB
SATA SSD that is 72% full. microk8s v1.36.5 from 1.36/edge, snap held.
35 Argo CD apps, all Synced/Healthy; every Longhorn volume has one
replica. Backups go to the NAS (192.168.1.99): Longhorn to NFS at 00:00
(7 kept), Velero to MinIO at 01:00 (daily kept 30 days, weekly 90 days).
Gatus on s1 (node001, Hetzner) and s2 (home) watch each other and alert
through ntfy. node001 runs mail and tunnels the public hosts home.

## Follow-ups from this week

From docs/upgrade-k8s-1.33.md, docs/immich-scouts-online.md and
docs/longhorn-second-ssd.md:

- [ ] Read `~/iosample.log` on opti1 once it stops (2026-10-25 14:35 UTC):
  sda's latency during the nightly Longhorn and Velero backups
- [ ] From 2026-10-27, if immich runs without problems: delete
  `immich/postgresql-cluster.yaml` (the PG14 cluster still runs, 20 GiB),
  the Longhorn snapshots and backups `immich-pg14-pre-vchord` and
  `immich-pg17-pre-v3`, and both dumps in `~` on opti1. PostgreSQL 14
  reaches end of life on 2026-11-12
- [ ] The upgrade's dqlite and backend copies in `/root/` on opti1
  (`backend-*.tar`, `dqlite-pre-*`)
- [ ] Log in to immich as a jeugdlid (quota 0)
- [ ] Back to 1.36/stable once it is at v1.36.5 or later. The snap is held,
  so microk8s gets no updates at all until someone refreshes it
- [ ] Second SSD, docs/longhorn-second-ssd.md
- [ ] Optional: `MACHINE_LEARNING_MODEL_REVISION=v2` for immich ML

## Next, in order

### 1. hensen.io expires

foto.scoutingmbg.nl is a CNAME to mbg.hensen.io, so when hensen.io lapses
the group loses its photos.

- [x] Expiry date: 2027-01-09 (whois, 2026-10-25; registrar Key-Systems)
- [ ] Before then: renew hensen.io for a year, or have the group's DNS
  point foto at the cluster without hensen.io

### 2. Off-site backups

Both backup targets are on the same NAS, in the same house as opti1. A
fire or burglary takes the cluster, the backups and 45,703 photos that
belong to the group.

- [ ] Check whether the NAS replicates anywhere. If not, a copy elsewhere
- [ ] Decide which copy of the immich library goes off-site (see 5)
- [ ] A restore test that runs on a schedule. `backup-testing/` predates
  Envoy Gateway and still rewrites `*.hensen.io` and bypasses sol-auth

### 3. authentik 2026.2.1

Since 2026-10-24 authentik is the front door for every member of the
group. Renovate PRs #20 (2026.2.3) and #22 (2026.8.5) have been open since
April and May.

- [ ] Check which releases still get security fixes and upgrade, one minor
  at a time, reading the release notes for blueprints and outposts

### 4. Vault 1.17.2

The server is pinned and out of support. It unseals with Shamir keys, so
after every reboot (the SSD install, for one) Vault stays sealed and ESO
stops refreshing secrets until someone unseals it.

- [ ] Make sure the unseal keys are kept outside this cluster
- [ ] Add unsealing to the SSD install steps
- [ ] Upgrade the server (needs the unseal keys)

### 5. Backups: which tool keeps what

Findings from 2026-10-25:

- Velero backs up every mounted volume through kopia, including the immich
  library (133 GB), which Longhorn also backs up to the same NAS. Most runs
  take 10s to 3 min, since kopia only reads changed files. 3 of the last 13
  read everything again: 37 min on 10-21, 30 min on 10-24 (the lease loss
  at 01:09), 13 min for the weekly on 10-25. Why those runs found no
  usable parent is unclear; the 10-24 one was the first after the Velero
  1.18 upgrade restarted the node agent. Once Longhorn's data is on the
  NVMe SSD these reads no longer hit the disk dqlite is on.
- Velero holds the photos longest. Longhorn keeps 7 backups per volume
  (count-based, so extra runs push out older ones: immich-claim's oldest
  daily is from 10-22); Velero keeps dailies 30 days and weeklies 90.
  Dropping immich from Velero means raising Longhorn's retention first.
- Longhorn's recurring job skips detached volumes
  (`allow-recurring-job-while-volume-detached` is false). immich-claim got
  no Longhorn backup on 10-24: the server was at 0 replicas for the
  database migration from 22:18 to 00:06 UTC.
- Velero copies the CNPG and MariaDB data directories file by file while
  the databases run, which is not a consistent copy. The Longhorn backups
  start from a snapshot and are crash-consistent. CNPG can back up to
  MinIO itself (barman cloud plugin), with point-in-time recovery.
- The PartiallyFailed daily backup of 10-23 (emptyDirs of Velero's own
  maintenance job pods) was fixed that afternoon by
  `velero/skip-emptydir-policy.yaml`.

- [ ] Whether the immich library stays in Velero. It stays for now
  (2026-10-25); decide again with the off-site copy (2)
- [ ] CNPG backups through the barman cloud plugin

### 6. Monitoring

Nothing collects metrics or logs, not even metrics-server (`kubectl top`
fails). The dqlite stalls were tracked down by hand from the API server's
metrics.

- [ ] After the second SSD (a time series database writes all the time
  and would add to today's stalls): metrics-server, then Prometheus or
  VictoriaMetrics with Grafana, alerting to ntfy. Loki later
- [ ] Alerts worth having: disk latency and fill, lease losses and
  controller restarts, backups that don't complete, Longhorn volumes that
  aren't healthy, Vault sealed

### 7. Limits, probes, network policies

Counted 2026-10-25 over the 73 running containers:

- 59 have no requests and 64 no memory limit, among them all of Argo CD,
  authentik, cert-manager, ESO, mariadb-operator and Vault, and freshrss,
  gitea, immich and serpbear. The node has 32 GB with 14.6 GB in use; one
  runaway pod can take the node down, dqlite with it.
- No probes on gitea, freshrss, serpbear, authentik's LDAP outpost, the
  ESO controller, dex and Argo CD's redis.
- NetworkPolicies exist only in argocd and longhorn-system. Public are
  immich (every member, plus public share links), mbgwp (WordPress) and
  authentik.
- Running as root as far as the securityContext tells (images not
  checked): authentik, bolletjestrui, freshrss, gatus, gitea, immich,
  ntfy, serpbear, mariadb-operator.

- [ ] Default-deny NetworkPolicies, immich, mbgwp and authentik first
- [ ] Requests and memory limits, the big ones first (immich, authentik,
  Argo CD's repo-server)
- [ ] Probes
- [ ] Non-root where the image allows it

### 8. Renovate and CI

10 Renovate PRs are open, the oldest from February, and nothing checks a
PR before Argo CD applies it.

- [ ] A GitHub Actions workflow that renders the Helm apps and runs
  kubeconform on every PR, with conftest for this repo's rules
- [ ] Automerge patch versions of low-risk apps once that runs

### 9. One node

One node, one SSD, one replica per volume. The second SSD takes away the
disk contention; a second and third node (nix-infra, like node001) is the
step after that, if downtime starts to matter.

### 10. Repo and cluster cleanup

- [ ] `disable/` (empty, untracked); `.DS_Store` into `.gitignore`
- [ ] `secrets/hensenio-smtp.yaml` (for the removed `blog` namespace) and
  `velero/minio-es.yaml` are commented out in full
- [ ] `backup-testing/test-velero-backup.sh.bak`
- [ ] `mbgwp-pre-migration-backup` in mbgwp: a 10 GiB volume and a
  completed pod from 2026-02-22, not in git

## wishlist.txt (2026-01-25)

- Done: Renovate; secrets out of git (Vault and ESO); SSO through authentik
  (Argo CD, Vault, Longhorn, FreshRSS, Actual, mail, immich); Gitea as a
  GitHub alternative; nix-infra for node001; most of the repo cleanup.
- Partly: network policies, probes, requests and limits, non-root (7);
  backup testing (a script, not scheduled; 2); understanding Longhorn
  (docs/longhorn-second-ssd.md).
- Open: Prometheus, Grafana, Loki, Alertmanager and which alerts (6);
  conftest and CI/CD (8); Trivy; a staging environment; an image registry;
  three nodes and opti1 on nix-infra (9); less manual work per new app.
  kube-hunter is no longer developed; the Trivy Operator or kube-bench
  cover that ground.
- Dropped: shrinking the immich PVC to 200 GB. Longhorn can't shrink a
  volume, and with personal accounts the library will grow. Deleting stale
  snapshots (docs/longhorn-second-ssd.md) frees more.
