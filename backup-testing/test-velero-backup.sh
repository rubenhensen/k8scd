#!/bin/bash
# test-velero-backup.sh - Automated script to test Velero backups
#
# This script creates a temporary K3d cluster, installs necessary components,
# and restores a Velero backup for testing. Ingresses are automatically
# rewritten from *.hensen.io to *.local for local testing.
#
# Authentication proxies (sol-auth) are excluded and ingresses are rewritten
# to point directly to backend services.

set -e

# Configuration - customize these variables
BACKUP_NAME=""
S3_BUCKET="velero-backups"
S3_REGION="minio"
S3_URL="http://192.168.1.99:9000"
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
ORIGINAL_NAMESPACE=""
TEST_NAMESPACE="default"
DEBUG=false
ORIGINAL_DOMAIN="hensen.io"
LOCAL_DOMAIN="local"
SKIP_INGRESS_SETUP=false
GENERATE_HOSTS=false

# Auth proxy configuration - these will be excluded and bypassed
AUTH_PROXY_SERVICE="sol-auth-svc"
AUTH_PROXY_PORT="8002"

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
    --original-domain)
      ORIGINAL_DOMAIN="$2"
      shift 2
      ;;
    --local-domain)
      LOCAL_DOMAIN="$2"
      shift 2
      ;;
    --skip-ingress-setup)
      SKIP_INGRESS_SETUP=true
      shift
      ;;
    --generate-hosts)
      GENERATE_HOSTS=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --backup-name NAME         Name of the Velero backup to restore"
      echo "  --s3-bucket BUCKET         S3 bucket containing backups (default: velero-backups)"
      echo "  --s3-region REGION         S3 region (default: minio)"
      echo "  --s3-url URL               S3 endpoint URL (default: http://192.168.1.99:9000)"
      echo "  --s3-access-key KEY        S3 access key"
      echo "  --s3-secret-key KEY        S3 secret key"
      echo "  --original-namespace NS    Namespace in the original backup"
      echo "  --test-namespace NS        Namespace for restoration (default: default)"
      echo "  --original-domain DOMAIN   Domain to replace (default: hensen.io)"
      echo "  --local-domain DOMAIN      Local domain suffix (default: local)"
      echo "  --skip-ingress-setup       Skip nginx-ingress and cert-manager installation"
      echo "  --generate-hosts           Generate /etc/hosts entries for local DNS"
      echo "  --debug                    Enable debug output"
      echo "  --help                     Show this help message"
      echo ""
      echo "Notes:"
      echo "  - Sol-auth proxy resources are automatically excluded from restore"
      echo "  - Ingresses pointing to sol-auth are rewritten to point directly to backends"
      echo "  - Certificates are excluded; self-signed certs are used instead"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Verify required variables
if [[ -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" || -z "$ORIGINAL_NAMESPACE" ]]; then
  echo "Error: Required parameters missing"
  echo "Required: --s3-access-key, --s3-secret-key, --original-namespace"
  echo "Run with --help for usage information"
  exit 1
fi

# Check for required tools
for tool in docker kubectl helm k3d velero jq; do
  if ! command -v "$tool" &> /dev/null; then
    echo "Error: Required tool '$tool' is not installed"
    exit 1
  fi
done

# Function to clean up resources
cleanup() {
  echo "Cleaning up resources..."
  k3d cluster delete backup-test 2>/dev/null || true
  rm -f velero-credentials 2>/dev/null || true
  echo "Cleanup complete"
}

# Function for debugging output
debug() {
  if [[ "$DEBUG" == "true" ]]; then
    echo "[DEBUG] $*"
  fi
}

# Function to install nginx-ingress controller
install_nginx_ingress() {
  echo "Installing nginx-ingress controller..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update ingress-nginx

  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=LoadBalancer \
    --set controller.watchIngressWithoutClass=true \
    --set controller.ingressClassResource.default=true \
    --wait

  echo "Waiting for nginx-ingress to be ready..."
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=120s
}

# Function to install cert-manager with self-signed issuer
install_cert_manager() {
  echo "Installing cert-manager..."
  helm repo add jetstack https://charts.jetstack.io
  helm repo update jetstack

  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --wait

  echo "Waiting for cert-manager to be ready..."
  kubectl -n cert-manager rollout status deployment/cert-manager --timeout=120s
  kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=120s

  # Create self-signed ClusterIssuers (including one named like production for compatibility)
  echo "Creating self-signed ClusterIssuers..."
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: prod-cluster-issuer
spec:
  selfSigned: {}
EOF

  echo "cert-manager installed with self-signed issuers"
}

# Function to rewrite ingress hosts from original domain to local domain
rewrite_ingress_hosts() {
  local namespace="$1"
  echo "Rewriting ingress hosts from *.$ORIGINAL_DOMAIN to *.$LOCAL_DOMAIN in namespace $namespace..."

  local ingresses
  ingresses=$(kubectl get ingress -n "$namespace" -o name 2>/dev/null || true)

  if [[ -z "$ingresses" ]]; then
    echo "No ingresses found in namespace $namespace"
    return
  fi

  for ingress in $ingresses; do
    local ingress_name
    ingress_name=$(echo "$ingress" | cut -d'/' -f2)
    debug "Processing ingress: $ingress_name"

    # Get current hosts and rewrite rules
    local current_hosts
    current_hosts=$(kubectl get ingress -n "$namespace" "$ingress_name" -o jsonpath='{.spec.rules[*].host}')
    debug "Current hosts: $current_hosts"

    local rule_index=0
    for host in $current_hosts; do
      if [[ "$host" == *".$ORIGINAL_DOMAIN" ]]; then
        local new_host="${host%.$ORIGINAL_DOMAIN}.$LOCAL_DOMAIN"
        echo "  Rewriting host: $host -> $new_host"
        kubectl patch ingress -n "$namespace" "$ingress_name" --type=json \
          -p "[{\"op\": \"replace\", \"path\": \"/spec/rules/$rule_index/host\", \"value\": \"$new_host\"}]" 2>/dev/null || true
      fi
      ((rule_index++)) || true
    done

    # Update TLS hosts if present
    local tls_count
    tls_count=$(kubectl get ingress -n "$namespace" "$ingress_name" -o jsonpath='{.spec.tls}' 2>/dev/null | jq -r 'length // 0' 2>/dev/null || echo "0")

    for ((tls_index=0; tls_index<tls_count; tls_index++)); do
      local tls_hosts
      tls_hosts=$(kubectl get ingress -n "$namespace" "$ingress_name" -o jsonpath="{.spec.tls[$tls_index].hosts[*]}" 2>/dev/null || true)
      local host_index=0
      for host in $tls_hosts; do
        if [[ "$host" == *".$ORIGINAL_DOMAIN" ]]; then
          local new_host="${host%.$ORIGINAL_DOMAIN}.$LOCAL_DOMAIN"
          kubectl patch ingress -n "$namespace" "$ingress_name" --type=json \
            -p "[{\"op\": \"replace\", \"path\": \"/spec/tls/$tls_index/hosts/$host_index\", \"value\": \"$new_host\"}]" 2>/dev/null || true
        fi
        ((host_index++)) || true
      done
    done

    # Update cert-manager annotation to use self-signed issuer
    kubectl annotate ingress -n "$namespace" "$ingress_name" \
      cert-manager.io/cluster-issuer=selfsigned-issuer --overwrite 2>/dev/null || true
  done

  echo "Ingress host rewriting complete"
}

# Function to bypass auth proxies by rewriting ingress backends
bypass_auth_proxy() {
  local namespace="$1"
  echo "Bypassing auth proxy ($AUTH_PROXY_SERVICE) in namespace $namespace..."

  local ingresses
  ingresses=$(kubectl get ingress -n "$namespace" -o name 2>/dev/null || true)

  if [[ -z "$ingresses" ]]; then
    echo "No ingresses found in namespace $namespace"
    return
  fi

  for ingress in $ingresses; do
    local ingress_name
    ingress_name=$(echo "$ingress" | cut -d'/' -f2)

    # Get the ingress JSON
    local ingress_json
    ingress_json=$(kubectl get ingress -n "$namespace" "$ingress_name" -o json)

    # Check if any backend points to the auth proxy service
    if echo "$ingress_json" | grep -q "$AUTH_PROXY_SERVICE"; then
      echo "  Found auth proxy in ingress: $ingress_name"

      # Get the number of rules
      local rule_count
      rule_count=$(echo "$ingress_json" | jq '.spec.rules | length')

      for ((rule_idx=0; rule_idx<rule_count; rule_idx++)); do
        local path_count
        path_count=$(echo "$ingress_json" | jq ".spec.rules[$rule_idx].http.paths | length")

        for ((path_idx=0; path_idx<path_count; path_idx++)); do
          local backend_service
          backend_service=$(echo "$ingress_json" | jq -r ".spec.rules[$rule_idx].http.paths[$path_idx].backend.service.name")

          if [[ "$backend_service" == "$AUTH_PROXY_SERVICE" ]]; then
            # Find the actual backend service by looking at other services in the namespace
            # For Immich, this is helm-immich-server on port 2283
            local real_backend="helm-immich-server"
            local real_port=2283

            echo "    Rewriting: $AUTH_PROXY_SERVICE:$AUTH_PROXY_PORT -> $real_backend:$real_port"

            kubectl patch ingress -n "$namespace" "$ingress_name" --type=json \
              -p "[{\"op\": \"replace\", \"path\": \"/spec/rules/$rule_idx/http/paths/$path_idx/backend/service/name\", \"value\": \"$real_backend\"},
                  {\"op\": \"replace\", \"path\": \"/spec/rules/$rule_idx/http/paths/$path_idx/backend/service/port/number\", \"value\": $real_port}]" 2>/dev/null || true
          fi
        done
      done
    fi
  done

  echo "Auth proxy bypass complete"
}

# Function to generate /etc/hosts entries
generate_hosts_entries() {
  local namespace="$1"
  echo ""
  echo "=== /etc/hosts entries ==="
  echo "Add the following lines to your /etc/hosts file:"
  echo ""

  local ingresses
  ingresses=$(kubectl get ingress -n "$namespace" -o name 2>/dev/null || true)

  if [[ -z "$ingresses" ]]; then
    echo "# No ingresses found in namespace $namespace"
    return
  fi

  for ingress in $ingresses; do
    local ingress_name
    ingress_name=$(echo "$ingress" | cut -d'/' -f2)
    local hosts
    hosts=$(kubectl get ingress -n "$namespace" "$ingress_name" -o jsonpath='{.spec.rules[*].host}')
    for host in $hosts; do
      echo "127.0.0.1    $host"
    done
  done

  echo ""
  echo "=== End of /etc/hosts entries ==="
  echo ""
}

# Register cleanup function to run on exit
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

kubectl config use-context k3d-backup-test
kubectl get nodes

# Test network connectivity to MinIO from within the cluster
echo "Testing connectivity to MinIO from cluster..."
S3_HOST=$(echo "$S3_URL" | sed -E 's|https?://([^:/]+).*|\1|')
S3_PORT=$(echo "$S3_URL" | sed -E 's|https?://[^:/]+:([0-9]+).*|\1|')
S3_PORT=${S3_PORT:-9000}

# Run a test pod to check connectivity
kubectl run nettest --image=busybox:1.36 --restart=Never -- sleep 60 2>/dev/null || true
if ! kubectl wait --for=condition=Ready pod/nettest --timeout=60s 2>/dev/null; then
  echo "Warning: Test pod not ready, skipping connectivity test"
else
  if kubectl exec nettest -- wget -q -O /dev/null --timeout=5 "http://$S3_HOST:$S3_PORT/minio/health/live" 2>/dev/null; then
    echo "Connectivity to MinIO ($S3_HOST:$S3_PORT): OK"
  elif kubectl exec nettest -- nc -zv -w5 "$S3_HOST" "$S3_PORT" 2>&1 | grep -qE "open|succeeded"; then
    echo "Connectivity to MinIO ($S3_HOST:$S3_PORT): OK"
  else
    echo ""
    echo "ERROR: Cannot reach MinIO at $S3_HOST:$S3_PORT from within the cluster"
    echo ""
    echo "Debug info:"
    echo "  - k3d network: $(docker network inspect k3d-backup-test --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo 'unknown')"
    echo ""
    echo "The k3d cluster cannot route to your LAN. Possible fixes:"
    echo "  1. Add a route on your NAS firewall for Docker subnets (172.x.x.x)"
    echo "  2. Check if iptables is blocking traffic: sudo iptables -L -n | grep 172"
    echo ""
    kubectl delete pod nettest --ignore-not-found >/dev/null 2>&1 || true
    exit 1
  fi
fi
kubectl delete pod nettest --ignore-not-found >/dev/null 2>&1 || true

# 2. Install ingress and certificate management
if [[ "$SKIP_INGRESS_SETUP" != "true" ]]; then
  install_nginx_ingress
  install_cert_manager
else
  echo "Skipping ingress and cert-manager setup (--skip-ingress-setup)"
fi

# 3. Install Velero with S3 provider
echo "Installing Velero..."
cat > velero-credentials <<EOF
[default]
aws_access_key_id=$S3_ACCESS_KEY
aws_secret_access_key=$S3_SECRET_KEY
EOF

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update vmware-tanzu

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

echo "Waiting for Velero to be fully ready..."
kubectl -n velero rollout status deployment/velero --timeout=120s

echo "Installing storage class mapping..."
kubectl apply -f change-storage-class.yaml

# Check if velero CLI is installed
if ! command -v velero &> /dev/null; then
  echo "Error: Velero CLI is not installed or not in PATH"
  echo "Install from: https://velero.io/docs/main/basic-install/"
  exit 1
fi

# Verify Velero is connected to the storage location
echo "Checking Velero backup storage location..."
BSL_AVAILABLE=false
for i in {1..32}; do
  BSL_STATUS=$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "$BSL_STATUS" == "Available" ]]; then
    echo "Backup storage location is available"
    BSL_AVAILABLE=true
    break
  fi
  echo "Waiting for backup storage location... ($i/32) - Status: $BSL_STATUS"
  if [[ "$DEBUG" == "true" ]]; then
    echo "[DEBUG] BackupStorageLocation details:"
    kubectl -n velero get backupstoragelocation default -o yaml 2>/dev/null || true
  fi
  sleep 5
done

if [[ "$BSL_AVAILABLE" != "true" ]]; then
  echo ""
  echo "ERROR: Backup storage location did not become available"
  echo ""
  echo "This usually means the k3d cluster cannot reach your MinIO server at $S3_URL"
  echo ""
  echo "Possible solutions:"
  echo "  1. Use host.k3d.internal instead of the IP address:"
  echo "     --s3-url http://host.k3d.internal:9000"
  echo ""
  echo "  2. If MinIO is on your host machine, ensure it's listening on all interfaces"
  echo ""
  echo "  3. Check BackupStorageLocation status:"
  kubectl -n velero get backupstoragelocation default -o yaml 2>/dev/null || true
  exit 1
fi

# 4. Wait for backups to sync from S3
echo "Waiting for Velero to sync backups from S3..."
BACKUP_FOUND=false
for i in {1..32}; do
  velero_output=$(velero backup get 2>&1) || true
  if echo "$velero_output" | grep -q "^$BACKUP_NAME "; then
    BACKUP_FOUND=true
    break
  fi
  echo "Waiting for backup list to sync... ($i/32)"
  sleep 5
done

echo "Available backups:"
velero backup get 2>&1 || true
echo ""

if [[ -z "$BACKUP_NAME" ]]; then
  echo "Specify a backup name using --backup-name and run again."
  exit 0
fi

if [[ "$BACKUP_FOUND" != "true" ]]; then
  echo "ERROR: Backup '$BACKUP_NAME' not found after waiting"
  echo ""
  echo "This could mean:"
  echo "  1. The backup name is incorrect"
  echo "  2. The backup doesn't exist in the S3 bucket"
  echo "  3. Velero needs more time to sync"
  echo ""
  echo "You can check available backups on your production cluster:"
  echo "  velero backup get"
  exit 1
fi
echo "Found backup: $BACKUP_NAME"

# 5. Create test namespace if needed
if [[ "$TEST_NAMESPACE" != "default" ]]; then
  kubectl create namespace "$TEST_NAMESPACE" 2>/dev/null || true
fi

# 6. Restore backup (excluding auth proxy and certificates)
echo "Restoring backup: $BACKUP_NAME"
echo "  Excluding: sol-auth resources, certificates"

RESTORE_NAME="test-restore-$(date +%s)"

if [[ -z "$ORIGINAL_NAMESPACE" ]]; then
  velero restore create "$RESTORE_NAME" \
    --from-backup "$BACKUP_NAME" \
    --exclude-resources certificates.cert-manager.io \
    --wait
else
  velero restore create "$RESTORE_NAME" \
    --from-backup "$BACKUP_NAME" \
    --namespace-mappings "$ORIGINAL_NAMESPACE:$TEST_NAMESPACE" \
    --include-namespaces "$ORIGINAL_NAMESPACE" \
    --exclude-namespaces kube-system,kube-public,kube-node-lease,velero \
    --exclude-resources certificates.cert-manager.io \
    --wait
fi

# 7. Check restore status
echo "Checking restore status:"
velero restore describe "$RESTORE_NAME"

# 8. Delete sol-auth resources (they were restored from backup)
echo "Removing sol-auth resources..."
kubectl delete deployment -n "$TEST_NAMESPACE" sol-auth 2>/dev/null || true
kubectl delete service -n "$TEST_NAMESPACE" "$AUTH_PROXY_SERVICE" 2>/dev/null || true
kubectl delete configmap -n "$TEST_NAMESPACE" httpd-conf 2>/dev/null || true
# Wait for sol-auth pod to terminate
kubectl wait --for=delete pod -l app=sol-auth -n "$TEST_NAMESPACE" --timeout=60s 2>/dev/null || true

# 9. Wait for pods to be ready
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod --all -n "$TEST_NAMESPACE" --timeout=600s 2>/dev/null || true

# 10. Rewrite ingress configuration for local testing
if [[ "$SKIP_INGRESS_SETUP" != "true" ]]; then
  bypass_auth_proxy "$TEST_NAMESPACE"
  rewrite_ingress_hosts "$TEST_NAMESPACE"
fi

# 11. Generate /etc/hosts entries if requested
if [[ "$GENERATE_HOSTS" == "true" ]]; then
  generate_hosts_entries "$TEST_NAMESPACE"
fi

# 12. Run validation
echo "Running validation tests..."
./validate-restore.sh "$TEST_NAMESPACE"

echo ""
echo "=== Backup test process completed ==="
echo ""
echo "Cluster: k3d-backup-test"
echo "Namespace: $TEST_NAMESPACE"
echo "Context: kubectl config use-context k3d-backup-test"
echo ""
echo "The cluster will be deleted when you press Enter or Ctrl+C"

read -p "Press Enter to clean up and exit..."
