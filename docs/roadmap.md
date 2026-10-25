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

There is no off-site copy (2026-10-25). The plan: swap S3 buckets with a
friend.

- [ ] Ours to his bucket: Hyper Backup on the Synology, destination "S3
  Storage" with his endpoint as a custom server. Client-side encryption
  on: the kopia repositories use Velero's default password
  (`static-passw0rd`), so without it he could read everything, the
  group's photos included. Keep the encryption key next to the Vault
  unseal key. Source: the shared folder with MinIO's `velero-backups`
  bucket (~150-200 GB). Daily after the Velero backup, Smart Recycle,
  mail on failure
- [ ] Needed from him: endpoint, which S3 server he runs, space (~200 GB
  now, 500 GB to grow), and versioning or object lock on the bucket, so
  whoever takes over the NAS can't delete the off-site copy as well
- [ ] His backups with us: Garage (not MinIO, see 5) in Container Manager
  on the Synology, in its own shared folder, with a bucket and key for him
  and a quota. Only the S3 API public, as `s3.rubenhensen.nl` through
  node001 and Envoy with a cert-manager certificate; the admin API stays
  on the LAN. The cluster side (DNS, node001 tunnel, Certificate,
  HTTPRoute) goes in git. Needed: how much space he wants, free space on
  the NAS
- [ ] Decide which copy of the immich library goes off-site (see 5)
- [ ] A restore test that runs on a schedule. `backup-testing/` predates
  Envoy Gateway and still rewrites `*.hensen.io` and bypasses sol-auth

### 3. authentik 2026.2.1 → 2026.8.5

Since 2026-10-24 authentik is the front door for every member of the
group. Renovate PRs #20 (2026.2.3) and #22 (2026.8.5) had been open since
April and May.

- [x] Upgraded 2026-10-25 in two hops, since releases can't be skipped:
  chart 2026.5.6, then 2026.8.5. Each took about three minutes with no
  downtime; the old pods kept serving until the new ones were ready.
  Safety net: `pg_dump -Fc` in `~/authentik-pre-2026.5.dump` (15 MB) on
  opti1 and Longhorn snapshot `authentik-pg-pre-2026-5`. Checked after
  each hop: the seven OIDC discovery endpoints and their issuers, the
  login page, immich, every blueprint successful, the LDAP outpost
  checking in on the new version
  - 2026.5 listens on `[::]` instead of `0.0.0.0`. IPv6 is on in the pods
    (`bindv6only` 0), so IPv4 keeps working
  - 2026.8 only believes `X-Forwarded-*` from
    `listen.trusted_proxy_cidrs`, which defaults to the private ranges
    (10.0.0.0/8 covers Envoy's pods); redirects stay https
  - The managed LDAP outpost didn't follow on its own after either hop;
    `outpost_controller.send(<outpost pk>)` in `ak shell` rolled it over
  - The `redis:` values were left over from before authentik dropped
    Redis; the chart has no such key, so they went
- [x] Log in once through each app: immich through Scouts Online, Argo CD,
  Vault, Longhorn, FreshRSS, Actual, mail
- [ ] After a week without problems: delete the dump and the snapshot
- [ ] Base URL (system setting or `AUTHENTIK_WEB__BASE_URL`) becomes
  required in 2026.11. authentik answers on authentik.rubenhensen.nl and
  auth.scoutingmbg.nl (immich's issuer), so find out first what the
  setting does with two hostnames

### 4. Vault 1.17.2 → 2.2.1

Vault unseals with Shamir keys, so after every reboot (the SSD install,
for one) it stays sealed and ESO stops refreshing secrets until someone
unseals it.

- [x] Upgraded 2026-10-25, straight from 1.17.2 to 2.2.1. HashiCorp
  doesn't require going through every release, and the change tracker
  lists no breaking change that applies here: `disable_mlock` is set
  (required for raft since 1.20), the chart sets `SKIP_SETCAP` and runs
  Vault as uid 100 (2.0.1's IPC_LOCK requirement, dropped again in 2.0.2),
  and ESO uses a token and KV v2. `tools/vault-roll.sh 2.2.1` restarted
  the standbys first and the active node last, unsealing each; vault-1
  took over as active within seconds. Safety net: Longhorn snapshots
  `vault-{0,1,2}-pre-2-2-1`. Afterwards all three ran 2.2.1 at the same
  raft index, and all 24 ExternalSecrets refreshed after a force-sync
  - The OIDC job called `vault auth tune -listing_visibility`, a flag that
    doesn't exist, so the OIDC mount's listing visibility was never set.
    Fixed; the job now uses the 2.2.1 CLI instead of 1.15
- [ ] There is one unseal key (1 share, threshold 1). Keep it in two
  places outside this cluster; without it the data in Vault is lost
- [x] Unsealing is in the SSD install steps
- [ ] After a week without problems: delete the three snapshots

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
- [ ] Velero's target, MinIO on the NAS, is no longer maintained: no
  community images since October 2025, maintenance mode since December
  2025, and the repository is archived. Move Velero to the Garage from 2
  and switch MinIO off

### 6. Monitoring

Nothing collects metrics or logs, not even metrics-server (`kubectl top`
fails). The dqlite stalls were tracked down by hand from the API server's
metrics, and Velero's scheduled backups failed every night from August
until 2026-10-21 without anyone noticing.

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

- [x] NetworkPolicies for immich, mbgwp and authentik
  (`<namespace>/networkpolicy.yaml`, 2026-10-25). Before, WordPress could
  reach the NAS's DSM, the router, the API server, Vault and immich. Now
  each of the three reaches only its own pods, DNS and the internet
  (without the private ranges), plus the API server for the CNPG
  instances and authentik's worker. Ingress only from Envoy, the CNPG and
  MariaDB operators, the node (kubelet probes) and, for the LDAP outpost,
  from anywhere. Checked afterwards: the sites, the OIDC endpoints and
  logins, Longhorn's login through Envoy, the LDAP NodePort, CNPG
  healthy, a MariaDB backup and a share-sync run. The node's addresses
  (192.168.1.204 and Calico's 10.1.7.64) are written out, so a new node
  means new policies
- [x] The same for gitea, freshrss, serpbear, ntfy, actual-budget,
  bolletjestrui and gatus (2026-10-25), plus gatus → ntfy in-cluster.
  home-assistant has no pods (it points at 192.168.1.202). Vault now only
  takes connections from ESO, Envoy (the UI) and the node (the injector's
  webhook); its pods reach each other, DNS, the API server and the
  internet. Checked: every host answers as before, gatus s2 16/16, the
  OIDC logins of Vault and FreshRSS reach authentik, all 24
  ExternalSecrets refresh, raft intact; Gitea no longer reaches the NAS
  or Vault, and a pod in `default` no longer reaches Vault or Gitea
- [ ] The infrastructure namespaces (cert-manager, cnpg-system,
  external-secrets, envoy-gateway-system, velero, mariadb-system, dns,
  default) still have none; `default` can reach the LAN and everything
  without a policy
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

- [x] Done 2026-10-25: `disable/` and the `.DS_Store` files, now in
  `.gitignore`; `secrets/hensenio-smtp.yaml` and `velero/minio-es.yaml`
  (commented out in full), and with the first the `secrets-folder` app;
  `backup-testing/test-velero-backup.sh.bak` (an older copy); the 15
  completed kopia maintenance jobs of repositories that no longer exist
  (nextcloud, owntracks, sogo, sogo-mail, ttrss)
- [ ] `kubectl delete namespace secrets`, empty since its app went
- [ ] 41 Failed Velero backups: the dailies from 2026-09-26 to 10-21 and
  the weeklies since 08-02. Velero doesn't restore from a Failed backup;
  left alone they expire by 2027-01-16.
  `kubectl -n velero exec deploy/velero -c velero -- /velero backup delete $(kubectl -n velero get backups.velero.io -o json | jq -r '.items[] | select(.status.phase=="Failed") | .metadata.name' | xargs) --confirm`
- [ ] The mariadb-operator Backup `mbgwp-pre-migration-backup`, a dump
  from 2026-02-22 on its own 10 GiB volume (which has a Longhorn backup
  from 2026-10-22). The PVC has no owner, so it goes separately:
  `kubectl -n mbgwp delete backups.k8s.mariadb.com mbgwp-pre-migration-backup && kubectl -n mbgwp delete pvc mbgwp-pre-migration-backup`
- [ ] 50 of the 70 Longhorn backup volumes on the NAS belong to volumes
  that no longer exist. Keep the final backups of 2026-10-22 (ghost-blog,
  stalwart, whisper). The rest are from apps removed long ago: nextcloud
  (2025-03), owntracks, traccar, ttrss, whisper-priv, whisper-webui,
  ghost, sogo, sogo-mail, outrun-game, the old mbg-wordpress and
  mbgwp-helm volumes, immich's database before CNPG. Decide per app and
  delete in the Longhorn UI (Backup)
- [ ] opti1, without sudo: `rm ~/calico-3.29.3.yaml ~/cni-3.25.1-backup.yaml ~/hosts.toml.docker.io.bak ~/dqlite-vacuum`,
  rollback material for steps that can't be undone any more (the tool's
  source is in tools/)
- [ ] opti1, with sudo: `/root/backend-*` and `/root/dqlite-pre-*` (from
  before 1.33, 1.34 and the VACUUM; 1.34 migrated the schema, so none of
  them fits 1.36) and `~/containerd.bak` (root-owned, from 2025-02)
- [ ] `~/cadir` on opti1 holds a CA key and certificate from 2026-03-21
  that are not microk8s's current CA. Find out whether anything still
  trusts it; if not, delete it

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
