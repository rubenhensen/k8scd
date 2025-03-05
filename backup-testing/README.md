# Velero Backup Testing Guide

This guide explains how to test your Velero backups using a temporary K3d cluster.

## Prerequisites

Ensure you have the following tools installed on your local machine:

- Docker
- kubectl
- Helm
- K3d
- Velero CLI

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
--test-namespace <NAMESPACE>
```

This will:
+ Create a temporary K3d cluster
+ Install Velero configured to access your MinIO backup location
+ List available backups
+ Allow you to test restoring a specific backup

To restore a specific backup, run:

## Testing Specific Applications

### Immich

For testing Immich backups:

```bash
./test-velero-backup.sh \
  --s3-access-key <ACCESS_KEY> \
  --s3-secret-key <SECRET_KEY> \
  --backup-name immich \
  --original-namespace immich \
  --test-namespace immich

kubectl port-forward service/helm-immich-server -n immich 8080:2283
```
Reachable on `localhost:8080`



## Testing with Volume Snapshots (not tested yet)

To test CSI volume snapshot backups:

```bash
./test-velero-backup.sh \
  --s3-access-key YOUR_ACCESS_KEY \
  --s3-secret-key YOUR_SECRET_KEY \
  --original-namespace immich \
  --include-volume-snapshots
```

## Customizing Validation (not tested yet)

You can extend the `validate-restore.sh` script to perform application-specific validation checks:

1. Edit the script to add application-specific checks
2. Run your test with the modified validation:

```bash
./test-velero-backup.sh \
  --s3-access-key YOUR_ACCESS_KEY \
  --s3-secret-key YOUR_SECRET_KEY \
  --original-namespace immich \
  --backup-name your-backup \
  --custom-validation-script ./your-custom-validation.sh
```

## Troubleshooting (not tested yet)

If you encounter issues:

1. Check the logs of the Velero pod:
   ```
   kubectl logs -n velero deploy/velero
   ```

2. Examine restore details:
   ```
   velero restore describe RESTORE_NAME
   velero restore logs RESTORE_NAME
   ```

3. Check cluster resources:
   ```
   kubectl get pods -A
   kubectl get pvc -A
   ```
