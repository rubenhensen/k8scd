#!/bin/bash
# test-velero-backup.sh - Automated script to test Velero backups

set -e

# Configuration - customize these variables
BACKUP_NAME=""          # Will list backups if empty
S3_BUCKET="velero-backups"
S3_REGION="minio"
S3_URL="http://192.168.1.99:9000"               # Your NAS MinIO server
S3_ACCESS_KEY=""  # Will be filled from credentials
S3_SECRET_KEY=""  # Will be filled from credentials
ORIGINAL_NAMESPACE=""   # Namespace in the original backup
TEST_NAMESPACE="default"
DEBUG=false             # Set to true for verbose debugging

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --backup-name)
      BACKUP_NAME="$2"
      shift 2
      ;;
    --s3-access-key)
      S3_ACCESS_KEY="$2"
      shift 2
      ;;
    --s3-secret-key)
      S3_SECRET_KEY="$2"
      shift 2
      ;;
    --s3-bucket)
      S3_BUCKET="$2"
      shift 2
      ;;
    --s3-region)
      S3_REGION="$2"
      shift 2
      ;;
    --s3-url)
      S3_URL="$2"
      shift 2
      ;;
    --original-namespace)
      ORIGINAL_NAMESPACE="$2"
      shift 2
      ;;
    --test-namespace)
      TEST_NAMESPACE="$2"
      shift 2
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --backup-name NAME         Name of the Velero backup to restore"
      echo "  --s3-bucket BUCKET         S3 bucket containing backups"
      echo "  --s3-region REGION         S3 region"
      echo "  --s3-url URL               S3 endpoint URL"
      echo "  --s3-access-key KEY        S3 access key"
      echo "  --s3-secret-key KEY        S3 secret key"
      echo "  --original-namespace NS    Namespace in the original backup"
      echo "  --test-namespace NS        Namespace for restoration (default: default)"
      echo "  --debug                    Enable debug output"
      echo "  --help                     Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Verify required variables
if [[ -z "$S3_BUCKET" || -z "$S3_REGION" || -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" || -z "$ORIGINAL_NAMESPACE" || -z "$TEST_NAMESPACE" ]]; then
  echo "Error: S3 configuration is incomplete"
  exit 1
fi

# Function to clean up resources
cleanup() {
  echo "Cleaning up resources..."
  k3d cluster delete backup-test || true
  echo "Cleanup complete"
}

# Function for debugging output
debug() {
  if [[ "$DEBUG" == "true" ]]; then
    echo "[DEBUG] $*"
  fi
}

# Register cleanup function to run on exit (ctrl+c, etc.)
trap cleanup EXIT

echo "=== Starting Velero backup test process ==="

# 1. Create K3d cluster
echo "Creating K3d cluster..."
k3d cluster create backup-test \
  --api-port 6443 \
  --port "80:80@loadbalancer" \
  --port "443:443@loadbalancer" \
  --agents 0 \
  --k3s-arg "--disable=traefik@server:0" \
  --wait
  # -v /mnt/longhorn:/var/lib/longhorn:shared@all \
  # -i hebury/k3s:v1.32.2-k3s1  \
  # --wait

# Verify cluster is running
kubectl config use-context k3d-backup-test
kubectl get nodes

# 2. Install Longhorn
# echo "Installing Longhorn..."
# kubectl create namespace longhorn-system

# helm repo add longhorn https://charts.longhorn.io
# helm repo update

# helm install longhorn longhorn/longhorn \
#   --namespace longhorn-system \
#   --set persistence.defaultClassReplicaCount=1 \
#   --set defaultSettings.backupTarget="" \
#   --set defaultSettings.defaultReplicaCount=1

# echo "Waiting for Longhorn to be ready..."
# kubectl -n longhorn-system rollout status deployment/longhorn-ui
# kubectl -n longhorn-system rollout status deployment/longhorn-driver-deployer
# kubectl -n longhorn-system rollout status daemonset/longhorn-manager

# 3. Install Velero with S3 provider
echo "Installing Velero..."
cat > velero-credentials <<EOF
[default]
aws_access_key_id=$S3_ACCESS_KEY
aws_secret_access_key=$S3_SECRET_KEY
EOF

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

debug "Installing Velero with S3 configuration:"
debug "  Bucket: $S3_BUCKET"
debug "  Region: $S3_REGION"
debug "  URL: $S3_URL"

helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set-file credentials.secretContents.cloud=velero-credentials \
  --set configuration.backupStorageLocation[0].provider=aws \
  --set configuration.backupStorageLocation[0].name=default \
  --set configuration.backupStorageLocation[0].bucket=$S3_BUCKET \
  --set configuration.backupStorageLocation[0].config.region=$S3_REGION \
  --set configuration.backupStorageLocation[0].config.s3ForcePathStyle=true \
  --set configuration.backupStorageLocation[0].config.s3Url=$S3_URL \
  --set configuration.volumeSnapshotLocation[0].name=default \
  --set configuration.volumeSnapshotLocation[0].provider=aws \
  --set configuration.volumeSnapshotLocation[0].config.region=$S3_REGION \
  --set configuration.features=EnableCSI \
  --set initContainers[0].name=velero-plugin-for-aws \
  --set initContainers[0].image=velero/velero-plugin-for-aws:v1.11.1 \
  --set initContainers[0].volumeMounts[0].mountPath=/target \
  --set initContainers[0].volumeMounts[0].name=plugins \
  --set deployNodeAgent=true \
  --set nodeAgent.containerSecurityContext.privileged=true \
  --wait

rm velero-credentials

# Wait for Velero to be ready
echo "Waiting for Velero to be fully ready..."
kubectl -n velero rollout status deployment/velero --timeout=120s

echo "Install change-storage-class.yaml"
kubectl apply -f change-storage-class.yaml

# Check if velero CLI is installed and functioning
if ! command -v velero &> /dev/null; then
  echo "Error: Velero CLI is not installed or not in PATH"
  echo "Please install the Velero CLI by following instructions at: https://velero.io/docs/main/basic-install/"
  exit 1
fi

# Verify Velero is connected to the storage location
echo "Checking Velero backup storage location..."
kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' | grep -q "Available" || {
  echo "Warning: Backup storage location is not available, it may take a few minutes to initialize"
  echo "Storage location status:"
  kubectl -n velero get backupstoragelocation default -o yaml
  
  # Wait a bit longer for the location to become available
  echo "Waiting 30 seconds for backup storage location to become available..."
  sleep 30
}

# 4. List backups
echo "Checking for available backups..."
if ! velero_output=$(velero backup get 2>&1); then
  echo "Error listing backups: $velero_output"
  
  # Try to verify S3 connectivity
  echo "Checking S3 connectivity..."
  
  # Install AWS CLI if needed
  if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found, skipping S3 connectivity test"
  else
    # Create temporary AWS profile
    mkdir -p ~/.aws
    cat > ~/.aws/credentials <<EOF
[velero-test]
aws_access_key_id=$S3_ACCESS_KEY
aws_secret_access_key=$S3_SECRET_KEY
EOF

    cat > ~/.aws/config <<EOF
[profile velero-test]
region=$S3_REGION
output=json
EOF

    # Try to list bucket contents
    echo "Testing S3 connection to bucket $S3_BUCKET..."
    if aws --profile velero-test --endpoint-url $S3_URL s3 ls s3://$S3_BUCKET/; then
      echo "S3 connection successful, but Velero couldn't list backups."
      echo "This might indicate that there are no backups in the bucket or the backups are in a different format than expected."
    else
      echo "Error connecting to S3. Please check your credentials and connectivity to $S3_URL"
    fi
    
    # Cleanup AWS files
    rm ~/.aws/credentials ~/.aws/config
  fi
  
  if [[ -z "$BACKUP_NAME" ]]; then
    echo "No backup name specified and no backups found. Exiting."
    exit 1
  fi
else
  echo "Available backups:"
  echo "$velero_output"
  
  if [[ -z "$BACKUP_NAME" ]]; then
    echo "Specify a backup name using --backup-name and run again."
    exit 0
  fi
fi

# 5. Create test namespace if needed
if [[ "$TEST_NAMESPACE" != "default" ]]; then
  kubectl create namespace $TEST_NAMESPACE || true
fi

# 6. Restore backup
echo "Restoring backup: $BACKUP_NAME"
if [[ -z "$ORIGINAL_NAMESPACE" ]]; then
  # If no namespace specified, restore everything
  velero restore create --from-backup $BACKUP_NAME \
    --wait
else
  # Restore specific namespace with mapping
  velero restore create --from-backup $BACKUP_NAME \
    --namespace-mappings $ORIGINAL_NAMESPACE:$TEST_NAMESPACE \
    --include-namespaces $ORIGINAL_NAMESPACE \
    --exclude-namespaces kube-system,kube-public,kube-node-lease,velero \
    --exclude-resources certificates.cert-manager.io \ 
    --wait
fi

# 7. Check restore status
echo "Checking restore status:"
velero restore get

# Wait for pods to be ready
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod --all -n $TEST_NAMESPACE --timeout=300s || true

# 8. Run validation script (create it first if it doesn't exist)
# if [[ ! -f ./validate-restore.sh ]]; then
#   echo "Creating validation script..."
#   cat > validate-restore.sh <<'EOF'
# #!/bin/bash
# # validate-restore.sh - Script to validate Velero backup restoration

# set -e
# echo "Starting validation of restored resources..."

# # Get namespace from command line or use default
# NAMESPACE="${1:-default}"

# # Check all deployments
# echo "Checking deployments..."
# deployments=$(kubectl get deployment -n $NAMESPACE -o name)
# if [[ -z "$deployments" ]]; then
#   echo "❌ No deployments found in namespace $NAMESPACE"
# else
#   echo "Found deployments: $deployments"
  
#   # Check if pods are running for each deployment
#   for deployment in $deployments; do
#     name=$(echo $deployment | cut -d'/' -f2)
#     echo -n "Checking deployment $name: "
    
#     # Check if pods are running
#     ready_replicas=$(kubectl get deployment -n $NAMESPACE $name -o jsonpath='{.status.readyReplicas}')
#     if [[ -n "$ready_replicas" && "$ready_replicas" != "0" ]]; then
#       echo "✅ $ready_replicas pods ready"
#     else
#       echo "❌ No pods running"
#     fi
#   done
# fi

# # Check all services
# echo "Checking services..."
# services=$(kubectl get service -n $NAMESPACE -o name | grep -v "kubernetes")
# if [[ -z "$services" ]]; then
#   echo "❌ No services found in namespace $NAMESPACE"
# else
#   echo "Found services: $services"
  
#   # Check if services have endpoints
#   for service in $services; do
#     name=$(echo $service | cut -d'/' -f2)
#     echo -n "Checking service $name: "
    
#     # Check if service has endpoints
#     endpoints=$(kubectl get endpoints -n $NAMESPACE $name -o jsonpath='{.subsets[*].addresses[*].ip}')
#     if [ -n "$endpoints" ]; then
#       echo "✅ Has endpoints"
#     else
#       echo "❌ No endpoints"
#     fi
#   done
# fi

# # Check PVCs
# echo "Checking PVCs..."
# pvcs=$(kubectl get pvc -n $NAMESPACE -o name)
# if [[ -z "$pvcs" ]]; then
#   echo "No PVCs found in namespace $NAMESPACE"
# else
#   pvc_count=$(echo "$pvcs" | wc -l)
#   echo "Found $pvc_count PVCs"
  
#   # Check if PVCs are bound
#   bound_count=$(kubectl get pvc -n $NAMESPACE -o jsonpath='{.items[?(@.status.phase=="Bound")].metadata.name}' | wc -w)
#   echo "$bound_count/$pvc_count PVCs are bound"
  
#   if [ "$bound_count" -ne "$pvc_count" ]; then
#     echo "❌ Not all PVCs are bound"
#   else
#     echo "✅ All PVCs are bound"
#   fi
# fi

# echo "Validation complete!"
# exit 0
# EOF
#   chmod +x validate-restore.sh
# fi

echo "Running validation tests..."
./validate-restore.sh $TEST_NAMESPACE

echo ""
echo "=== Backup test process completed ==="
echo "The cluster will be deleted when you close this terminal or press Ctrl+C"
echo "To access the cluster manually, use: kubectl config use-context k3d-backup-test"
echo ""

# Keep the script running until user terminates it
read -p "Press Enter to clean up and exit..."