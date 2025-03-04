#!/bin/bash
# validate-restore.sh - Script to validate Velero backup restoration

set -e
echo "Starting validation of restored resources..."

# Get namespace from command line or use default
NAMESPACE="${1:-default}"

# Check all deployments
echo "Checking deployments..."
deployments=$(kubectl get deployment -n $NAMESPACE -o name)
if [[ -z "$deployments" ]]; then
  echo "❌ No deployments found in namespace $NAMESPACE"
else
  echo "Found deployments: $deployments"
  
  # Check if pods are running for each deployment
  for deployment in $deployments; do
    name=$(echo $deployment | cut -d'/' -f2)
    echo -n "Checking deployment $name: "
    
    # Check if pods are running
    ready_replicas=$(kubectl get deployment -n $NAMESPACE $name -o jsonpath='{.status.readyReplicas}')
    if [[ -n "$ready_replicas" && "$ready_replicas" != "0" ]]; then
      echo "✅ $ready_replicas pods ready"
    else
      echo "❌ No pods running"
    fi
  done
fi

# Check all services
echo "Checking services..."
services=$(kubectl get service -n $NAMESPACE -o name | grep -v "kubernetes")
if [[ -z "$services" ]]; then
  echo "❌ No services found in namespace $NAMESPACE"
else
  echo "Found services: $services"
  
  # Check if services have endpoints
  for service in $services; do
    name=$(echo $service | cut -d'/' -f2)
    echo -n "Checking service $name: "
    
    # Check if service has endpoints
    endpoints=$(kubectl get endpoints -n $NAMESPACE $name -o jsonpath='{.subsets[*].addresses[*].ip}')
    if [ -n "$endpoints" ]; then
      echo "✅ Has endpoints"
    else
      echo "❌ No endpoints"
    fi
  done
fi

# Check PVCs
echo "Checking PVCs..."
pvcs=$(kubectl get pvc -n $NAMESPACE -o name)
if [[ -z "$pvcs" ]]; then
  echo "No PVCs found in namespace $NAMESPACE"
else
  pvc_count=$(echo "$pvcs" | wc -l)
  echo "Found $pvc_count PVCs"
  
  # Check if PVCs are bound
  bound_count=$(kubectl get pvc -n $NAMESPACE -o jsonpath='{.items[?(@.status.phase=="Bound")].metadata.name}' | wc -w)
  echo "$bound_count/$pvc_count PVCs are bound"
  
  if [ "$bound_count" -ne "$pvc_count" ]; then
    echo "❌ Not all PVCs are bound"
  else
    echo "✅ All PVCs are bound"
  fi
fi

echo "Validation complete!"
exit 0
