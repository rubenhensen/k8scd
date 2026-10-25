#!/bin/bash
# Restore a few namespaces from the real Velero backups into a throwaway
# k3s in Docker, to prove the backups can be restored. Nothing on the NAS
# changes:
# - one backup (backups/<name>/) and the kopia repositories of the chosen
#   namespaces (kopia/<namespace>/) are copied read-only from the NAS with
#   rclone into a Docker volume. A second Velero on the real bucket could
#   run kopia maintenance on the same repositories as the cluster's own
# - `rclone serve s3` serves that copy to a Velero 1.18.2 in k3s, with a
#   ReadOnly backup storage location
# - storage class longhorn becomes local-path; only core workload
#   resources are restored (no routes, certificates, ExternalSecrets or
#   NetworkPolicies)
# - every pod volume restore has to complete with as many bytes as its
#   backup had, and the restored deployments have to become available
#
# Usage (on a machine with docker, kubectl and jq):
#   backup-testing/restore-test.sh [backup] [namespace ...]
# Defaults: the newest Completed daily-backup, and ntfy freshrss
# actual-budget. Not gatus: a restored Gatus would start sending alerts.
#
# It reads Velero's S3 key from the cluster (velero/velero-s3-credentials)
# into a temporary directory, and the copied backup holds every Secret of
# the cluster; all of it is deleted at the end. KEEP=1 keeps the test
# cluster (kubeconfig in the printed directory) until you run it with
# CLEANUP=1. FROM_VOLUME=<docker volume> takes the bucket from a volume
# instead of the NAS (for rehearsals; laid out as <bucket>/backups/...).
#
# Rehearsed on 2026-10-25 against a backup made in the test cluster itself,
# which is how two pitfalls showed up: Velero skips hostPath volumes, and
# k3s only provisions local PVs (which it can back up and restore) for a
# storage class with the annotation defaultVolumeType: local.
set -euo pipefail

PROD_KUBECONFIG=${PROD_KUBECONFIG:-$HOME/.kube/homelab-config}
PORT=${PORT:-16443}
K3S=rancher/k3s:v1.34.9-k3s1
RCLONE=rclone/rclone:1.75.1
HELM=alpine/helm:3.19.0
VELERO_CHART=12.2.1
AWS_PLUGIN=velero/velero-plugin-for-aws:v1.14.4
NET=restore-test VOL=restore-test-s3

cleanup() {
  docker rm -f -v restore-k3s restore-s3 >/dev/null 2>&1 || true
  docker volume rm "$VOL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [[ -n ${WORK:-} ]] && rm -rf "$WORK"
}
if [[ ${CLEANUP:-} == 1 ]]; then
  cleanup; rm -rf "${TMPDIR:-/tmp}"/restore-test.*; echo "cleaned up"; exit 0
fi
if docker ps -a --format '{{.Names}}' | grep -qx restore-k3s; then
  echo "A test cluster from an earlier run exists; run with CLEANUP=1 first." >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/restore-test.XXXXXX")
chmod 700 "$WORK"
[[ ${KEEP:-} == 1 ]] || trap cleanup EXIT

pk() { kubectl --kubeconfig "$PROD_KUBECONFIG" "$@"; }
tk() { kubectl --kubeconfig "$WORK/kubeconfig" "$@"; }
# wait_for <seconds> <what> <command...>
wait_for() {
  local limit=$1 what=$2; shift 2
  local end=$((SECONDS + limit))
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS > end)); then echo "timed out waiting for $what" >&2; exit 1; fi
    sleep 5
  done
}

# Endpoint, region and bucket as Velero itself uses them. The NAS rejects a
# request signed for the wrong region (rclone defaults to us-east-1); MinIO
# did so with a bare 400 on HEAD.
if [[ -n ${FROM_VOLUME:-} ]]; then
  BUCKET=${BUCKET:-velero-backups}
else
  bsl=$(pk -n velero get backupstoragelocations default -o json)
  S3URL=${S3URL:-$(jq -r '.spec.config.s3Url' <<<"$bsl")}
  REGION=${REGION:-$(jq -r '.spec.config.region // "us-east-1"' <<<"$bsl")}
  BUCKET=${BUCKET:-$(jq -r '.spec.objectStorage.bucket' <<<"$bsl")}
fi

backup=${1:-}
shift || true
namespaces=("$@")
[[ ${#namespaces[@]} -gt 0 ]] || namespaces=(ntfy freshrss actual-budget)
if [[ -z $backup ]]; then
  backup=$(pk -n velero get backups.velero.io -o json | jq -r '[.items[]
    | select(.metadata.labels["velero.io/schedule-name"] == "daily-backup" and .status.phase == "Completed")]
    | max_by(.status.startTimestamp).metadata.name')
fi
echo "== backup $backup, namespaces: ${namespaces[*]}"

docker network create "$NET" >/dev/null
docker volume create "$VOL" >/dev/null
if [[ -n ${FROM_VOLUME:-} ]]; then
  echo "== copy from the volume $FROM_VOLUME"
  docker run --rm -v "$FROM_VOLUME:/from:ro" -v "$VOL:/data" alpine:3.22 cp -a /from/. /data/
else
echo "== copy from the NAS (read-only)"
(umask 077; pk -n velero get secret velero-s3-credentials -o jsonpath='{.data.cloud}' | base64 -d |
  awk -F' *= *' '/aws_access_key_id/ {print "RCLONE_CONFIG_NAS_ACCESS_KEY_ID="$2}
                 /aws_secret_access_key/ {print "RCLONE_CONFIG_NAS_SECRET_ACCESS_KEY="$2}' > "$WORK/nas.env"
  printf 'RCLONE_CONFIG_NAS_TYPE=s3\nRCLONE_CONFIG_NAS_PROVIDER=Other\nRCLONE_CONFIG_NAS_ENDPOINT=%s\nRCLONE_CONFIG_NAS_REGION=%s\n' "$S3URL" "$REGION" >> "$WORK/nas.env")
copy() { docker run --rm --env-file "$WORK/nas.env" -v "$VOL:/data" "$RCLONE" copy --stats-one-line "nas:$BUCKET/$1" "/data/$BUCKET/$1"; }
copy "backups/$backup"
for ns in "${namespaces[@]}"; do copy "kopia/$ns"; done
rm -f "$WORK/nas.env"
fi

echo "== local S3 and k3s"
docker run -d --name restore-s3 --network "$NET" -v "$VOL:/data" "$RCLONE" \
  serve s3 /data --addr :8080 --auth-key test,restore-test-secret >/dev/null
s3ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" restore-s3)
docker run -d --name restore-k3s --privileged --network "$NET" -p "127.0.0.1:$PORT:6443" "$K3S" \
  server --disable traefik --disable metrics-server --tls-san 127.0.0.1 --tls-san restore-k3s >/dev/null
node_ready() { docker exec restore-k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; }
wait_for 180 "k3s" node_ready
docker exec restore-k3s cat /etc/rancher/k3s/k3s.yaml | sed "s#https://127.0.0.1:6443#https://127.0.0.1:$PORT#" > "$WORK/kubeconfig"
docker exec restore-k3s cat /etc/rancher/k3s/k3s.yaml | sed 's#https://127.0.0.1:6443#https://restore-k3s:6443#' > "$WORK/kubeconfig-net"

echo "== Velero"
cat > "$WORK/values.yaml" <<EOF
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: $BUCKET
      accessMode: ReadOnly
      config:
        region: minio
        s3ForcePathStyle: "true"
        s3Url: http://$s3ip:8080
  volumeSnapshotLocation: []
  defaultRepoMaintainFrequency: 8760h
credentials:
  secretContents:
    cloud: |
      [default]
      aws_access_key_id=test
      aws_secret_access_key=restore-test-secret
initContainers:
  - name: velero-plugin-for-aws
    image: $AWS_PLUGIN
    volumeMounts:
      - mountPath: /target
        name: plugins
deployNodeAgent: true
snapshotsEnabled: false
upgradeCRDs: false
EOF
docker run --rm --network "$NET" -e HOME=/tmp -e KC="$(base64 < "$WORK/kubeconfig-net")" \
  -e VALUES="$(base64 < "$WORK/values.yaml")" --entrypoint sh "$HELM" -c '
  echo "$KC" | base64 -d > /tmp/kc && echo "$VALUES" | base64 -d > /tmp/v.yaml &&
  helm --kubeconfig /tmp/kc install velero velero --repo https://vmware-tanzu.github.io/helm-charts \
    --version '"$VELERO_CHART"' -n velero --create-namespace -f /tmp/v.yaml >/dev/null'
tk apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: change-storage-class
  namespace: velero
  labels:
    velero.io/plugin-config: ""
    velero.io/change-storage-class: RestoreItemAction
data:
  longhorn: local-path
EOF
wait_for 300 "Velero to sync $backup" tk -n velero get backups.velero.io "$backup"
echo "   Velero sees $backup"

echo "== restore"
tk apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: restore-test
  namespace: velero
spec:
  backupName: $backup
  includedNamespaces: [$(IFS=,; echo "${namespaces[*]}")]
  # PersistentVolumes have to be included: only then does Velero clear the
  # PVC's volumeName. It doesn't restore a PV whose data comes from kopia;
  # k3s provisions a new one.
  includedResources: [namespaces, persistentvolumeclaims, persistentvolumes, pods, deployments,
    replicasets, statefulsets, services, configmaps, secrets, serviceaccounts]
  restorePVs: true
EOF
restore_done() { [[ $(tk -n velero get restore restore-test -o jsonpath='{.status.phase}') =~ ^(Completed|PartiallyFailed|Failed|FailedValidation)$ ]]; }
wait_for 1800 "the restore" restore_done
phase=$(tk -n velero get restore restore-test -o jsonpath='{.status.phase}')
echo "   restore: $phase"

echo "== check"
failed=0
expected=$(docker run --rm -v "$VOL:/data" alpine:3.22 zcat "/data/$BUCKET/backups/$backup/$backup-podvolumebackups.json.gz" |
  jq -r --arg ns "$(IFS=,; echo "${namespaces[*]}")" '.[] | select(.spec.pod.namespace as $p | $ns | split(",") | index($p))
    | "\(.spec.pod.namespace)/\(.spec.volume) \(.status.progress.totalBytes // 0)"' | sort -u)
restored=$(tk -n velero get podvolumerestores.velero.io -o json |
  jq -r '.items[] | "\(.spec.pod.namespace)/\(.spec.volume) \(.status.progress.totalBytes // 0) \(.status.phase)"' | sort -u)
while read -r vol bytes; do
  [[ -z $vol ]] && continue
  got=$(awk -v v="$vol" '$1 == v {print $2, $3}' <<<"$restored")
  if [[ $got == "$bytes Completed" ]]; then
    echo "   ok      $vol ($bytes bytes)"
  else
    echo "   FAILED  $vol: backed up $bytes bytes, restore: ${got:-none}"; failed=1
  fi
done <<<"$expected"
for ns in "${namespaces[@]}"; do
  if tk -n "$ns" wait --for=condition=Available deployment --all --timeout=300s >/dev/null 2>&1; then
    echo "   ok      $ns: deployments available"
  else
    echo "   FAILED  $ns: deployments not available"; tk -n "$ns" get pods; failed=1
  fi
done
[[ $phase == Completed ]] || failed=1
[[ ${KEEP:-} == 1 ]] && echo "Kept; kubeconfig: $WORK/kubeconfig. Remove with CLEANUP=1 $0"
if [[ $failed == 0 ]]; then echo "== restore test passed"; else echo "== restore test FAILED"; exit 1; fi
