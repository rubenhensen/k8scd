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
- [ ] 1.11.2. Not 1.11.3 or 1.12.x: those need k8s 1.34

## 3. Smaller components

- [ ] CloudNativePG 1.25.1 → 1.26 → 1.27 → 1.28.4 (each step restarts the
  single-instance databases)
- [ ] Velero 1.15.2 → 1.16.x (chart 10.x), plugin-for-aws v1.12
- [ ] Vault chart 0.28.1 → ≥0.30.1 (vault-k8s 1.7.0)
- [ ] cert-manager 1.15.5 → 1.16.5 → 1.17.4 → 1.18.6 → 1.19.6 → 1.20.4
  (1.18 changes the `rotationPolicy` default to Always)

## 4. External Secrets 0.10.7 → ≥0.17

- [ ] Move every ExternalSecret and SecretStore to `external-secrets.io/v1`
- [ ] Upgrade one minor at a time; 0.16 needs v1alpha1 gone from
  `storedVersions`, 0.17 stops serving v1beta1, 0.19 needs server-side apply

## 5. Argo CD 2.14.2 → 3.4.12

- [ ] Read every upgrade note from
  [2.14→3.0](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/)
  onward. 3.0 switches to annotation tracking and excludes Endpoints and
  EndpointSlices by default (affects `home-assistant/service.yaml`); 3.3
  needs `kubectl apply --server-side --force-conflicts`

## 6. Calico 3.25.1 → 3.29.3

- [ ] Apply the manifest microk8s 1.33 ships
  (`/snap/microk8s/current/upgrade-scripts/000-switch-to-calico/resources/calico.yaml`
  after the refresh, or the 1.33 branch of canonical/microk8s before it).
  A snap refresh does not upgrade Calico.

## 7. microk8s 1.32 → 1.33

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
