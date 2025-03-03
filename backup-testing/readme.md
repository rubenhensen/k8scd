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
chmod +x setup-credentials.sh test-velero-backup.sh validate-restore.sh
```

3. Set up your MinIO credentials:

```bash
./setup-credentials.sh
```

This script will look for credentials in `~/.velero/credentials-velero` or prompt you to create them.

## Running a Backup Test

Execute the test script with appropriate parameters:

```bash
./test-velero-backup.sh \
  --s3-access-key YOUR_ACCESS_KEY \
  --s3-secret-key YOUR_SECRET_KEY \
  --original-namespace immich
```

This will:
1. Create a temporary K3d cluster
2. Install Longhorn for storage
3. Install Velero configured to access your MinIO backup location
4. List available backups
5. Allow you to test restoring a specific backup

To restore a specific backup, run:

```bash
./test-velero-backup.sh \
  --s3-access-key YOUR_ACCESS_KEY \
  --s3-secret-key YOUR_SECRET_KEY \
  --original-namespace immich \
  --backup-name specific-backup-name
```

## Testing Specific Applications

### Immich

For testing Immich backups:

```bash
./test-velero-backup.sh \
  --s3-access-key YOUR_ACCESS_KEY \
  --s3-secret-key YOUR_SECRET_KEY \
  --original-namespace immich \
  --test-namespace immich-test
```

### NextCloud

For testing NextCloud backups:

```bash
./test-velero-backup.sh \
  --s3-access-key YOUR_ACCESS_KEY \
  --s3-secret-key YOUR_SECRET_KEY \
  --original-namespace nextcloud \
  --test-namespace nextcloud-test
```

## Testing with Volume Snapshots

To test CSI volume snapshot backups:

```bash
./test-velero-backup.sh \
  --s3-access-key YOUR_ACCESS_KEY \
  --s3-secret-key YOUR_SECRET_KEY \
  --original-namespace immich \
  --include-volume-snapshots
```

## Customizing Validation

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

## Troubleshooting

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
