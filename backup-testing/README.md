# Velero Backup Testing Guide

This guide explains how to test your Velero backups using a temporary K3d cluster.

## Features

- Creates isolated K3d test cluster
- Installs nginx-ingress controller for ingress support
- Installs cert-manager with self-signed certificates (no real DNS/certs needed)
- Automatically rewrites ingress hosts from `*.hensen.io` to `*.local`
- Bypasses authentication proxies (sol-auth) by rewriting ingress backends
- Generates `/etc/hosts` entries for local DNS resolution
- Restores backups with storage class mapping (longhorn -> local-path)

## Prerequisites

Ensure you have the following tools installed on your local machine:

- Docker
- kubectl
- Helm
- K3d
- Velero CLI
- jq (for JSON parsing)

## Setup

1. First, clone this repository to your local machine:

```bash
git clone https://github.com/yourusername/backup-testing.git
cd backup-testing
```

2. Make the scripts executable:

```bash
chmod +x test-velero-backup.sh validate-restore.sh
```

## Running a Backup Test

Execute the test script with appropriate parameters:

```bash
./test-velero-backup.sh \
  --s3-access-key <ACCESS_KEY> \
  --s3-secret-key <SECRET_KEY> \
  --backup-name <BACKUP_NAME> \
  --original-namespace <NAMESPACE> \
  --test-namespace <NAMESPACE> \
  --generate-hosts
```

This will:
1. Create a temporary K3d cluster
2. Install nginx-ingress controller
3. Install cert-manager with self-signed ClusterIssuer
4. Install Velero configured to access your MinIO backup location
5. Restore the specified backup (excluding sol-auth and certificates)
6. Remove any restored sol-auth resources
7. Rewrite ingress backends from sol-auth to direct backend services
8. Rewrite ingress hosts from `*.hensen.io` to `*.local`
9. Generate `/etc/hosts` entries (with `--generate-hosts` flag)

## Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `--backup-name NAME` | Name of the Velero backup to restore | (lists backups if empty) |
| `--s3-access-key KEY` | S3/MinIO access key | (required) |
| `--s3-secret-key KEY` | S3/MinIO secret key | (required) |
| `--s3-bucket BUCKET` | S3 bucket containing backups | `velero-backups` |
| `--s3-region REGION` | S3 region | `minio` |
| `--s3-url URL` | S3 endpoint URL | `http://192.168.1.99:9000` |
| `--original-namespace NS` | Namespace in the original backup | (required) |
| `--test-namespace NS` | Namespace for restoration | `default` |
| `--original-domain DOMAIN` | Domain to replace in ingresses | `hensen.io` |
| `--local-domain DOMAIN` | Local domain suffix | `local` |
| `--skip-ingress-setup` | Skip nginx-ingress and cert-manager | `false` |
| `--generate-hosts` | Generate /etc/hosts entries | `false` |
| `--debug` | Enable debug output | `false` |

## Local DNS Resolution

After the restore completes, the script can generate `/etc/hosts` entries. Add these to your `/etc/hosts` file to access services locally:

```bash
# Example output with --generate-hosts:
127.0.0.1    foto.local
127.0.0.1    immich.local
```

Then access your restored services at `https://foto.local` or `https://immich.local`.

Note: Your browser will show certificate warnings since we use self-signed certificates. This is expected for local testing.

## Testing Specific Applications

### Immich

For testing Immich backups:

```bash
./test-velero-backup.sh \
  --s3-access-key <ACCESS_KEY> \
  --s3-secret-key <SECRET_KEY> \
  --backup-name daily-backup-YYYYMMDD \
  --original-namespace immich \
  --test-namespace immich \
  --generate-hosts
```

Then add the generated hosts entries and access via `https://immich.local`

Alternatively, use port-forwarding:
```bash
kubectl port-forward service/helm-immich-server -n immich 8080:2283
```
Reachable on `localhost:8080`



## Custom Domain Mapping

By default, the script rewrites `*.hensen.io` to `*.local`. You can customize this:

```bash
./test-velero-backup.sh \
  --s3-access-key YOUR_ACCESS_KEY \
  --s3-secret-key YOUR_SECRET_KEY \
  --backup-name your-backup \
  --original-namespace myapp \
  --original-domain example.com \
  --local-domain test.local
```

This will rewrite `app.example.com` to `app.test.local`.

## Authentication Proxy Bypass

The production environment uses `sol-auth` (an Apache httpd-based OpenID Connect proxy) to protect certain applications like Immich. For local testing, this authentication is bypassed:

1. **Sol-auth resources are removed** after restore (deployment, service, configmap)
2. **Ingress backends are rewritten** from `sol-auth-svc:8002` to the actual backend service (e.g., `helm-immich-server:2283`)

This allows you to access the application directly without needing to authenticate through the Scouting login portal.

**Production flow:**
```
Browser -> Ingress -> sol-auth-svc:8002 -> (OpenID auth) -> helm-immich-server:2283
```

**Test flow:**
```
Browser -> Ingress -> helm-immich-server:2283 (direct, no auth)
```

## Storage Class Mapping

The script automatically applies `change-storage-class.yaml` which maps:
- `longhorn` -> `local-path`

This allows backups from Longhorn storage to be restored using K3d's default local-path provisioner.

## Troubleshooting

### Check Velero logs
```bash
kubectl logs -n velero deploy/velero
```

### Examine restore details
```bash
velero restore describe <RESTORE_NAME>
velero restore logs <RESTORE_NAME>
```

### Check cluster resources
```bash
kubectl get pods -A
kubectl get pvc -A
kubectl get ingress -A
```

### Check ingress controller
```bash
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller
```

### Check cert-manager
```bash
kubectl get certificates -A
kubectl get clusterissuer
```

### Debug mode
Run with `--debug` for verbose output:
```bash
./test-velero-backup.sh --debug ...
```

## Architecture

```
+------------------+     +------------------+     +------------------+
|   K3d Cluster    |     |     MinIO        |     |   Your Browser   |
|                  |     |   (NAS/S3)       |     |                  |
|  +-----------+   |     |                  |     |                  |
|  |  Velero   |<--+-----+ velero-backups   |     |                  |
|  +-----------+   |     |     bucket       |     |                  |
|        |         |     +------------------+     |                  |
|        v         |                              |                  |
|  +-----------+   |                              |                  |
|  | Restored  |   |                              |                  |
|  |   App     |   |                              |                  |
|  +-----------+   |                              |                  |
|        |         |                              |                  |
|        v         |                              |                  |
|  +-----------+   |     *.local domains          |                  |
|  |  Ingress  |<---------------------------------+  https://app.local
|  |  nginx    |   |     (via /etc/hosts)         |                  |
|  +-----------+   |                              |                  |
|        |         |                              |                  |
|        v         |                              |                  |
|  +-----------+   |                              |                  |
|  |cert-manager|  |     Self-signed certs        |                  |
|  |(selfsigned)|  |                              |                  |
|  +-----------+   |                              |                  |
+------------------+                              +------------------+
```
