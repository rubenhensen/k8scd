#!/bin/bash
# setup-credentials.sh - Script to help setup credentials for Velero testing

# Directory where Velero credentials are stored on the production system
# This would be your production system's credentials for accessing MinIO
VELERO_CREDS_PATH="${HOME}/.velero/credentials-velero"

if [ -f "${VELERO_CREDS_PATH}" ]; then
  echo "Found Velero credentials at ${VELERO_CREDS_PATH}"
  # Extract AWS credentials from the file
  AWS_ACCESS_KEY_ID=$(grep aws_access_key_id ${VELERO_CREDS_PATH} | cut -d= -f2 | tr -d '[:space:]')
  AWS_SECRET_ACCESS_KEY=$(grep aws_secret_access_key ${VELERO_CREDS_PATH} | cut -d= -f2 | tr -d '[:space:]')
  
  if [ -n "${AWS_ACCESS_KEY_ID}" ] && [ -n "${AWS_SECRET_ACCESS_KEY}" ]; then
    echo "Credentials found and will be used for backup testing"
    
    # Store them temporarily for the test script to use
    cat > /tmp/velero-test-credentials <<EOF
[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
EOF
    
    echo "Credentials saved to /tmp/velero-test-credentials"
    echo ""
    echo "Run your test script with:"
    echo "./test-velero-backup.sh --s3-access-key ${AWS_ACCESS_KEY_ID} --s3-secret-key ${AWS_SECRET_ACCESS_KEY} [other options]"
  else
    echo "Error: Could not extract credentials from ${VELERO_CREDS_PATH}"
    exit 1
  fi
else
  echo "Error: Velero credentials file not found at ${VELERO_CREDS_PATH}"
  echo "Please create this file with the following format:"
  echo "[default]"
  echo "aws_access_key_id=YOUR_MINIO_ACCESS_KEY"
  echo "aws_secret_access_key=YOUR_MINIO_SECRET_KEY"
  exit 1
fi
