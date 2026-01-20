# Immich Upgrade Guide: v1.125.7 → v2.4.1 (Helm Chart 0.8.5 → 0.10.x)

This is a complex upgrade with multiple breaking changes. Follow this guide carefully.

## Overview of Breaking Changes

### Helm Chart 0.10.0 Breaking Changes
1. **PostgreSQL subchart REMOVED** - Must migrate to external PostgreSQL
2. **Redis subchart REMOVED** - Replaced with Valkey
3. **Common library updated** (1.4.0 → 4.3.0) - Completely different values.yaml structure
4. **Library mount path changed** - `/usr/src/app/upload` → `/data`

### Immich Application Breaking Changes
1. **v1.133.0**: Database vector extension migration (pgvecto.rs → VectorChord) - CRITICAL
2. **v1.133.0**: Mobile app version MUST match server version
3. **v1.136.0**: Absolute paths required for `IMMICH_MEDIA_LOCATION`
4. **v1.137.0**: TypeORM migration (must start on v1.132.0+ at least once)

---

## Pre-Upgrade Checklist

- [ ] Backup your PostgreSQL database
- [ ] Backup your photos (the `immich-claim` PVC)
- [ ] Note down your current PostgreSQL credentials
- [ ] Update your mobile app AFTER upgrading the server

---

## Phase 1: Backup Everything

### 1.1 Backup PostgreSQL Database

```bash
# Get the PostgreSQL pod name
kubectl get pods -n immich | grep postgresql

# Create a backup
kubectl exec -n immich helm-immich-postgresql-0 -- pg_dump -U immich -d immich -F c -f /tmp/immich-backup.dump

# Copy the backup locally
kubectl cp immich/helm-immich-postgresql-0:/tmp/immich-backup.dump ./immich-backup.dump
```

### 1.2 Backup Photos (optional but recommended)

```bash
# If you have access to the underlying storage, create a snapshot
# For Longhorn, you can create a snapshot via the UI or:
kubectl -n longhorn-system get volumes
```

---

## Phase 2: Deploy External PostgreSQL with CloudNativePG

The new helm chart requires external PostgreSQL. CloudNativePG is recommended.

### 2.1 Install CloudNativePG Operator

Create a new file `cloudnative-pg/helm-cnpg.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudnative-pg
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    chart: cloudnative-pg
    repoURL: https://cloudnative-pg.github.io/charts
    targetRevision: 0.23.0
    helm:
      values: |
        # Default values are fine
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  syncPolicy:
    syncOptions:
    - CreateNamespace=true
    automated:
      prune: true
      selfHeal: true
```

### 2.2 Create PostgreSQL Cluster for Immich

Create `immich/postgresql-cluster.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: immich-postgres
  namespace: immich
spec:
  instances: 1

  imageName: ghcr.io/immich-app/postgres:14-vectorchord0.3.0-pgvectors0.2.0

  postgresql:
    shared_preload_libraries:
      - "vchord.so"
      - "vectors.so"

  bootstrap:
    initdb:
      database: immich
      owner: immich
      postInitSQL:
        - CREATE EXTENSION IF NOT EXISTS vectors;
        - CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;
        - CREATE EXTENSION IF NOT EXISTS vchord CASCADE;

  storage:
    size: 10Gi
    storageClass: longhorn

  # To restore from backup, uncomment and configure:
  # bootstrap:
  #   recovery:
  #     source: immich-backup
```

### 2.3 Migrate Data from Old PostgreSQL

After the new cluster is ready:

```bash
# Get the new PostgreSQL password
kubectl get secret -n immich immich-postgres-app -o jsonpath='{.data.password}' | base64 -d

# Restore the backup to the new cluster
# First, copy the backup to the new pod
kubectl cp ./immich-backup.dump immich/immich-postgres-1:/tmp/immich-backup.dump

# Restore (this will also trigger the VectorChord migration when Immich starts)
kubectl exec -n immich immich-postgres-1 -- pg_restore -U immich -d immich -c /tmp/immich-backup.dump
```

---

## Phase 3: Update Helm Values for New Chart Structure

Replace your `helm-immich.yaml` with the new structure:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: helm-immich
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    automated:
      prune: true
      selfHeal: true
  project: default
  sources:
    - chart: immich
      repoURL: https://immich-app.github.io/immich-charts
      targetRevision: 0.10.3
      helm:
        values: |
          controllers:
            main:
              containers:
                main:
                  image:
                    tag: v2.4.1
                  env:
                    # External PostgreSQL connection
                    DB_HOSTNAME: "immich-postgres-rw"
                    DB_PORT: "5432"
                    DB_USERNAME: "immich"
                    DB_DATABASE_NAME: "immich"
                    # Reference the CNPG secret for password
                    DB_PASSWORD:
                      valueFrom:
                        secretKeyRef:
                          name: immich-postgres-app
                          key: password
                    # Valkey (Redis replacement)
                    REDIS_HOSTNAME: '{{ printf "%s-valkey" .Release.Name }}'
                    IMMICH_MACHINE_LEARNING_URL: '{{ printf "http://%s-machine-learning:3003" .Release.Name }}'

          immich:
            metrics:
              enabled: false
            persistence:
              library:
                existingClaim: immich-claim

          # Enable Valkey (Redis replacement)
          valkey:
            enabled: true
            persistence:
              data:
                enabled: true
                size: 1Gi
                storageClass: longhorn
                type: persistentVolumeClaim

          server:
            enabled: true
            controllers:
              main:
                containers:
                  main:
                    image:
                      repository: ghcr.io/immich-app/immich-server
                      pullPolicy: IfNotPresent
                    probes:
                      startup:
                        enabled: true
                        spec:
                          initialDelaySeconds: 0
                          timeoutSeconds: 1
                          periodSeconds: 5
                          failureThreshold: 1000
            ingress:
              main:
                enabled: true
                className: nginx
                annotations:
                  nginx.ingress.kubernetes.io/proxy-body-size: "0"
                  cert-manager.io/cluster-issuer: prod-cluster-issuer
                hosts:
                  - host: mbg.hensen.io
                    paths:
                      - path: "/"
                        service:
                          identifier: main
                  - host: foto.scoutingmbg.nl
                    paths:
                      - path: "/"
                        service:
                          identifier: main
                tls:
                  - secretName: letsencrypt-prod
                    hosts:
                      - mbg.hensen.io
                      - foto.scoutingmbg.nl

          machine-learning:
            enabled: true
            controllers:
              main:
                containers:
                  main:
                    image:
                      repository: ghcr.io/immich-app/immich-machine-learning
                      pullPolicy: IfNotPresent
                    env:
                      TRANSFORMERS_CACHE: /cache
                      HF_XET_CACHE: /cache/huggingface-xet
                      MPLCONFIGDIR: /cache/matplotlib-config
            persistence:
              cache:
                enabled: true
                size: 10Gi
                type: emptyDir

  destination:
    server: https://kubernetes.default.svc
    namespace: immich
```

---

## Phase 4: Execution Order

### Step 1: Disable Auto-Sync Temporarily
```bash
# Pause ArgoCD auto-sync for immich
kubectl patch application helm-immich -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

### Step 2: Scale Down Current Immich
```bash
kubectl scale deployment -n immich --all --replicas=0
kubectl scale statefulset -n immich --all --replicas=0
```

### Step 3: Backup Database (as shown in Phase 1)

### Step 4: Deploy CloudNativePG Operator
Push the CNPG application to your git repo and sync.

### Step 5: Deploy PostgreSQL Cluster
Push the cluster manifest and wait for it to be ready:
```bash
kubectl get cluster -n immich -w
```

### Step 6: Restore Database to New Cluster

### Step 7: Delete Old StatefulSets (they have immutable fields)
```bash
kubectl delete statefulset helm-immich-postgresql --cascade=orphan -n immich
kubectl delete statefulset helm-immich-redis-master --cascade=orphan -n immich
```

### Step 8: Update and Apply New Helm Values
Push the new `helm-immich.yaml` to git.

### Step 9: Re-enable Auto-Sync
```bash
kubectl patch application helm-immich -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### Step 10: Monitor the Migration
```bash
# Watch logs for VectorChord migration
kubectl logs -n immich -l app.kubernetes.io/name=immich-server -f
```

The first startup will take longer as it migrates the vector extension.

### Step 11: Update Mobile App
After confirming the server works, update your mobile app to match the server version.

---

## Troubleshooting

### StatefulSet Immutable Field Error
```bash
kubectl delete statefulset <name> --cascade=orphan -n immich
```

### VectorChord Migration Taking Too Long
This is normal for large libraries. The logs may appear stuck but it's reindexing.

### Database Connection Errors
Verify the CNPG cluster is ready:
```bash
kubectl get cluster -n immich
kubectl get pods -n immich | grep postgres
```

Check the secret exists:
```bash
kubectl get secret immich-postgres-app -n immich
```

### Library Mount Path Issues
If photos aren't visible, check that the PVC is mounted at `/data` (new default) instead of `/usr/src/app/upload`.

---

## Rollback Plan

If something goes wrong:

1. Keep your backup file (`immich-backup.dump`)
2. You can revert `helm-immich.yaml` in git to the old version
3. The old PostgreSQL data should still be on the PVC if you didn't delete it

---

## Notes About Your sol-auth-svc

Your current config routes through `sol-auth-svc` on port 8002. The new ingress config above routes directly to Immich. If you need the auth service, you'll need to configure that separately (it's not part of the standard helm chart).
