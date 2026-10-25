# Roadmap

Where the cluster stands and what is left, as of 2026-10-25. Takes over
from wishlist.txt (January 2026, removed); its items are sorted in at the
bottom.

## State

One node: opti1, an OptiPlex 5060 with an i5-8600T, 32 GB and one 1 TB
SATA SSD that is 72% full. microk8s v1.36.5 from 1.36/edge, snap held.
35 Argo CD apps (with metrics-server), all Synced/Healthy; every Longhorn
volume has one replica. authentik 2026.8.5, Vault 2.2.1. Backups go to the
NAS (192.168.1.99): Longhorn to NFS at 00:00 (7 kept), Velero to MinIO at
01:00 (daily kept 30 days, weekly 90 days). Gatus on s1 (node001, Hetzner)
and s2 (home) watch each other and alert through ntfy; s2 also gets an
hourly report from inside the cluster on the backups, Vault's seal, the
Argo CD apps and the CNPG clusters.
Every app namespace has NetworkPolicies, and CI renders and validates all
apps on every PR. node001 runs mail and tunnels the public hosts home.

## Follow-ups from this week

From docs/upgrade-k8s-1.33.md, docs/immich-scouts-online.md and
docs/longhorn-second-ssd.md:

- [x] Read `~/iosample.log` on opti1: the worst stretch was not the
  backups but 8.5 hours of Longhorn merging immich-claim's deleted
  snapshots (2026-10-24 14:30-23:15), see docs/upgrade-k8s-1.33.md
- [ ] From 2026-10-27, if immich runs without problems: delete
  `immich/postgresql-cluster.yaml` (the PG14 cluster still runs, 20 GiB),
  the Longhorn snapshots and backups `immich-pg14-pre-vchord` and
  `immich-pg17-pre-v3`, and both dumps in `~` on opti1. PostgreSQL 14
  reaches end of life on 2026-11-12
- [ ] The upgrade's dqlite and backend copies in `/root/` on opti1
  (`backend-*.tar`, `dqlite-pre-*`)
- [ ] Log in to immich as a jeugdlid (quota 0)
- [ ] Back to 1.36/stable once it is at v1.36.5 or later (still v1.36.2 on
  2026-10-25). The snap is held, so microk8s gets no updates at all until
  someone refreshes it
- [ ] Second SSD, docs/longhorn-second-ssd.md
- [ ] Optional: `MACHINE_LEARNING_MODEL_REVISION=v2` for immich ML

## Next, in order

### 1. hensen.io expires

foto.scoutingmbg.nl was a CNAME to mbg.hensen.io. Since 2026-10-24 it is a
CNAME to rubenhensen.nl (node001, which tunnels it home), but only on the
group's ns2: ns1 is stuck on an old serial and still answers
mbg.hensen.io (docs/immich-scouts-online.md).

- [x] Expiry date: 2027-01-09 (whois, 2026-10-25; registrar Key-Systems)
- [x] ns1 caught up on 2026-10-24 16:50 UTC; both ns1 and ns2 answer
  `rubenhensen.nl` for foto (checked 2026-10-25), and nothing in the
  cluster uses hensen.io anymore. hensen.io can expire

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
  Envoy Gateway and still rewrites `*.hensen.io` and bypasses sol-auth.
  Planned on 2026-10-25, not run: a second Velero on the real bucket is
  risky even with a ReadOnly location, because kopia could then run
  maintenance on the same repositories from two clusters. Instead: copy
  one backup (`backups/<name>/`) and the kopia repositories of a few small
  namespaces (`kopia/{gatus,ntfy,freshrss}/`) read-only from the NAS with
  rclone into a local folder, serve that with `rclone serve s3`, and
  restore into a throwaway k3s in Docker (Velero 1.18.2, node agent on,
  storage class longhorn mapped to local-path, without httproutes,
  certificates, referencegrants and networkpolicies). It needs the MinIO
  key outside the cluster, which wants your go-ahead; better still, a
  MinIO user with read-only access to `velero-backups`.
  Built as `backup-testing/restore-test.sh` (2026-10-25) and rehearsed
  end to end against a backup made inside the test cluster, with a
  ReadOnly location: data restored byte for byte (same sha256), deployment
  available, everything removed afterwards. Two pitfalls found on the way
  are in the script's header. Not yet run against the real backups:
- [ ] Run `backup-testing/restore-test.sh` (it reads the MinIO key from
  the cluster), then schedule it

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
- [x] Base URL (system setting or `AUTHENTIK_WEB__BASE_URL`), required
  from 2026.11: already `https://authentik.rubenhensen.nl`, filled in by
  the 2026.8 migration from the embedded outpost's host. In 2026.8.5 it is
  only stored; on main it fills itself in the same way and sets the
  embedded outpost's host from it. OIDC issuers still come from the
  request's host, so immich's issuer on auth.scoutingmbg.nl is unaffected
  (checked 2026-10-25 in the source)

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
- [x] There is one unseal key (1 share, threshold 1), kept safe outside
  this cluster (2026-10-25); without it the data in Vault is lost
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

- [x] A stopgap for the worst blind spots (2026-10-25,
  `gatus/backup-check.yaml`): an hourly CronJob reads the API and pushes
  six external endpoints to s2 (group "cluster"): the newest daily and
  weekly Velero backup Completed and recent, every attached Longhorn
  volume healthy with a backup younger than 26h, no Vault pod sealed,
  every Argo CD app Synced and Healthy, every CNPG cluster healthy.
  Gatus alerts through ntfy after two failed reports, or when no report
  arrives for 3 hours. The token comes from an ESO Password generator.
  Tested with made-up data for each failure (a Failed or old backup, a
  degraded or unbacked-up volume, a sealed pod)
- [x] metrics-server (2026-10-25, `apps/templates/metrics-server-helm.yaml`):
  `kubectl top` works; it keeps its data in memory, so it adds no disk
  writes. The first look: immich v3 checks file checksums every night from
  03:00 UTC for up to an hour (IntegrityService), reading ~100 MB/s from
  sda; it doesn't overlap the backups at 00:00 and 01:00
- [ ] After the second SSD (a time series database writes all the time
  and would add to today's stalls): Prometheus or
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
- [x] Requests: PR #33, merged 2026-10-25 11:23 UTC, for everything that
  had none except the Vault server, from `kubectl top` every 5 minutes
  from 03:13 to 08:40 UTC (highest memory plus 10%, CPU at p95, 10m
  floor). Rolled out in about eight minutes; both CNPG instances
  restarted and came back healthy, the OIDC endpoints, the logins and
  immich answered, no OOM kills. The node now has 3770m CPU (62%, of which
  1440m is Longhorn's two instance managers) and 9158Mi memory (28%)
  requested. Still without requests: Longhorn (22 containers, its chart),
  the Vault servers, the LDAP outpost, immich's PG14 cluster and three in
  kube-system
- [ ] Memory limits, once there are daytime numbers: the night ones miss
  immich's machine learning at work (it idles at 234Mi)
- [x] WordPress (scoutingmbg.nl) was OOMKilled at 08:27:59 UTC on
  2026-10-25, its third restart: a crawler asked for 88 pages and assets
  within a few seconds (normally ~6 a minute), Apache started a PHP worker
  for each (~45-60 MB each, `MaxRequestWorkers` was the default 150), and
  the container went past its 1Gi limit. Unrelated to the
  NetworkPolicies. Now capped at 12 workers through the chart's
  `apachePortsConfig` (ports.conf comes after mods-enabled/*.conf), checked
  with `apache2ctl -t` in the same image first. Replaying the burst (90
  page requests, 40 at a time): all 200, at most 13 Apache processes and
  572Mi, no restart; the price is waiting (4.3s median, up to ~22s at the
  peak) instead of a crash
- [ ] Optional, no plugins wanted on WordPress: a small nginx cache in the
  cluster between Envoy and WordPress that keeps anonymous GETs for a few
  minutes and passes anything with a WordPress cookie through. A page
  renders in 0.4-0.7s when the site is quiet and OPcache is on, so the
  waiting in a burst is queueing; the cap alone already prevents the crash
- [ ] Fewer plugins on the site (17 now; up to whoever runs it):
  `litespeed-cache` only caches pages on a LiteSpeed server, so it does
  little here, `wordpress-importer` is usually for a one-off import, and
  `code-snippets` runs PHP from the dashboard
- [ ] Rate limiting per visitor in Envoy needs the client's address, which
  node001 loses: it passes TLS through, so every request arrives from
  46.224.26.65. That needs the PROXY protocol from node001's nginx to Envoy
  (ClientTrafficPolicy `enableProxyProtocol`)
- [x] Probes for gitea (`/api/healthz`), freshrss (TCP, since
  mod_auth_openidc answers 401 to non-browsers) and serpbear (`/login`)
  (2026-10-25). Liveness only after 5 failures 30s apart, to ride out the
  SSD's stalls. Still without probes: authentik's LDAP outpost (deployed
  by authentik), the ESO controller, dex and Argo CD's redis (upstream
  manifests)
- [ ] Non-root where the image allows it

### 8. Renovate and CI

10 Renovate PRs are open, the oldest from February, and nothing checks a
PR before Argo CD applies it.

- [x] `.github/workflows/validate.yaml` runs `tools/ci/validate.py` on
  every PR and push (2026-10-25): it renders all 36 apps the way Argo CD
  does (the apps chart, every Application's chart with its values, value
  files and parameters, kustomizations, plain folders, and
  external-snapshotter cloned with its patches) and validates the result
  with kubeconform (strict, CRD schemas from the datree catalog), plus a
  duplicate-key check on every YAML file. Helm 4.2.1 like Argo CD 3.5,
  versions pinned and checksummed, kept current by Renovate through the
  `# renovate:` comments. Tested by planting a typo in a Deployment, a
  chart version that doesn't exist and a value the immich chart's schema
  rejects; all three fail the run. Locally:
  `docker run --rm -v $PWD:/repo:ro <image with helm, kustomize, kubeconform, PyYAML> python /repo/tools/ci/validate.py`
  - It found `syncPolicy.automated` twice in
    `apps/templates/snapshot-controller-helm.yaml` (once with `prune: true`,
    added 2025-03-03); Argo CD kept the last one, without prune. Now listed
    once, as it ran. Prune was probably meant; turn it on deliberately if so
- [x] This repo's own rules, in `tools/ci/validate.py` rather than
  conftest (2026-10-25), on what the repo's own folders render: no Secret
  with data in git, and every image has a tag other than latest (both
  fail the run; tested with a planted Secret and an untagged image), plus
  PR annotations for containers without requests or probes. freshrss's
  `alpine/git` init container had no tag; now `v2.52.0`
- [ ] Automerge patch versions of low-risk apps now that CI runs
- [x] Renovate listed external-snapshotter twice (#15 and #24): its
  `argocd` manager and a custom `github-tags` regex both matched. The
  regex is gone; Renovate should close #15 by itself
- [x] Renovate only looked at six folders for images and only at
  apps/templates for Applications, so it never offered updates for the
  vault, immich, velero, mariadb-operator and actualbudget charts, or for
  images in freshrss, mbgwp, dns, vault and immich, or for CNPG's
  `imageName` (authentik still runs PostgreSQL 17.4). Both managers now
  cover every app folder, a regex manager reads `imageName` in
  `*/postgresql-cluster*.yaml`, and major PostgreSQL updates are off
  (those need pg_upgrade or a dump). Expect a batch of new PRs
  (2026-10-25; `renovate-config-validator` passes). They only come once
  fewer than 10 Renovate PRs are open (`config:recommended`'s
  `prConcurrentLimit`); until then they wait under "Rate-Limited" on the
  Dependency Dashboard (#2)
- [x] Merged 2026-10-25 and checked after the sync: #28 cert-manager
  v1.21.3 (security release; all three pods on v1.21.3), #24
  external-snapshotter v8.7.0 (its manifests ship the v8.6.0 image, as
  v8.2.1 shipped v8.2.0; both replicas up, no errors), #25 WordPress chart
  0.16.7 (image unchanged, site 200), #31 python 3.15.1 (the cluster check
  ran clean on it). Closed: #19, #29, and #15 by Renovate. Later the same
  day: #23 ntfy v2.34.0, #27 go-dqlite v3.0.4, #33 (see 7) and #26 Gitea
  28.2.0 (migrations up to 357 ran clean, `/api/healthz` 200; no backup of
  its own beforehand, the nightly ones are the way back)
- [x] #17 external-secrets 2.14.0, merged 2026-10-25 11:50 UTC after a
  manual rebase (#33 had added values on the next line, which git counts
  as a conflict). All three pods on v2.14.0, the store Ready, and 24 of 25
  ExternalSecrets refreshed on a force-sync; the 25th is the generated
  `gatus/backup-check-token`, which never refreshes by design

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
- [ ] `rm -r ~/cadir` on opti1: a CA key and certificate made four minutes
  before the real keyUsage fix on 2026-03-21 (OpenSSL's default subject
  "Internet Widgits Pty Ltd", valid for a year) and never installed;
  microk8s's CA is the `CN=microk8s-ca` one from 19:16 that day, valid
  until 2036

### 11. Known vulnerabilities

A one-off scan on 2026-10-25 of all 52 images running in the cluster
(Trivy 0.75.0, remote, linux/amd64, HIGH and CRITICAL only). Counts are
critical / high:

| Image | Crit | High | What to do |
|---|---|---|---|
| tensorchord/cloudnative-pgvecto.rs:14-v0.2.1 | 38 | 342 | immich's old PG14 cluster; goes with the cleanup from 2026-10-27 |
| cloudnative-pg/postgresql:17.4 | 27 | 260 | authentik's database, a Debian 11 image. Renovate now offers 17.7; a `17.x-standard-trixie` image is more current |
| tensorchord/cloudnative-vectorchord:17.11-1.1.1 | 17 | 136 | immich's database; look for a newer tag |
| longhornio/longhorn-instance-manager:v1.7.3 | 11 | 159 | still serves 16 volumes, see below |
| actualbudget/actual-server:26.6.0 | 8 | 83 | chart 1.8.9; Renovate now covers it |
| gitea/gitea:1.27.3 | 8 | 43 | PR #26 (28.2.0) |
| immich-server / machine-learning v3.3.5 | 7, 7 | 113, 78 | a newer immich release |
| towfiqi/serpbear:3.1.0 | 6 | 77 | a newer release |
| rubenhensen/bolletjestrui:main-10268f1 | 5 | 76 | rebuild on a current base image |
| coredns/coredns:1.10.1 | 5 | 70 | see below |
| dexidp/dex:v2.45.1, argocd v3.5.6, redis 8.2.3 | 4, 1, 2 | | come with Argo CD |
| mariadb:11.4.5 | 4 | 65 | the newest 11.4 patch; Renovate now covers it |
| calico v3.29.3 | 2-3 | ~50 | comes with microk8s |
| goauthentik ldap / server 2026.8.5 | 3, 1 | 74, 65 | the next authentik patch |

Nothing critical in Envoy, Vault, Velero, cert-manager, ESO, ntfy, gatus or
metrics-server.

- [ ] 16 volumes still have their engine in Longhorn 1.7.3's instance
  manager (`instance-manager-07d66a5…`, running since March): vault ×3,
  authentik-postgres, immich-postgres (PG14), mbgwp (mariadb and
  wordpress), gitea, freshrss ×3, ntfy, gatus, serpbear, bolletjestrui,
  actual-budget. On one node a pod restart never detaches the volume (the
  new pod lands on the same node), so only a real detach moves the engine
  to 1.13's instance manager: scale to 0, wait until Longhorn shows the
  volume detached, scale back (Argo CD's selfHeal undoes a scale-down, so
  pause it for the app). Vault comes back sealed; CNPG clusters want
  `cnpg.io/hibernation=on` instead of a scale-down. The old instance
  manager goes away by itself once it serves nothing
- [ ] CoreDNS runs 1.10.1 from when the addon was enabled; the addon
  repository has 1.14.3. `sudo microk8s disable dns && sudo microk8s enable dns:1.1.1.1`
  (a short DNS outage for the whole cluster; check the Corefile after)
- [ ] The Trivy Operator for scans that keep running (on the wishlist)

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
