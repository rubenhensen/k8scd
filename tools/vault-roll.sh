#!/bin/bash
# Restart the Vault pods one at a time and unseal each one: the standbys
# first, the active node last, as HashiCorp's HA upgrade guide asks. The
# StatefulSet uses OnDelete, so this is how a new image from
# vault/overrides.yaml reaches the pods once Argo CD has synced it. Also
# useful after a reboot, minus the restarts: see "unseal only" below.
#
# Run it on a machine with kubectl access and the unseal key at hand:
#   tools/vault-roll.sh 2.2.1
# It asks for the key once per pod (hidden input) and stores nothing.
# Stop at any point with Ctrl-C; pods already done stay on the new version.
#
# Unseal only (after a reboot, all three come up sealed):
#   for p in vault-0 vault-1 vault-2; do kubectl -n vault exec -ti $p -- vault operator unseal; done
set -euo pipefail
ns=vault
target=${1:?usage: $0 <version the pods should run, e.g. 2.2.1>}

image=$(kubectl -n $ns get sts vault -o jsonpath='{.spec.template.spec.containers[0].image}')
if [[ $image != *:$target ]]; then
  echo "The StatefulSet has $image, not $target. Sync the vault app first." >&2
  exit 1
fi

pods() { kubectl -n $ns get pods -l "app.kubernetes.io/name=vault,component=server,vault-active=$1" -o name | sed 's|pod/||'; }
status() { kubectl -n $ns exec "$1" -- vault status -format=json 2>/dev/null || true; }
summary() {
  status "$1" | jq -r --arg p "$1" '"\($p): \(.version), sealed \(.sealed), \(if .is_self then "active" else "standby" end), raft index \(.raft_committed_index)"'
}

roll() {
  local pod=$1 rc
  echo
  echo "== $pod"
  kubectl -n $ns delete pod "$pod" --wait=true
  # vault status exits 0 when unsealed, 2 when sealed, 1 on errors (and
  # kubectl exec exits 1 while the container isn't running yet).
  while :; do
    rc=0
    kubectl -n $ns exec "$pod" -- vault status >/dev/null 2>&1 || rc=$?
    [[ $rc -ne 1 ]] && break
    sleep 2
  done
  if [[ $rc -eq 2 ]]; then
    kubectl -n $ns exec -ti "$pod" -- vault operator unseal
  fi
  kubectl -n $ns wait --for=condition=Ready "pod/$pod" --timeout=180s
  summary "$pod"
  local version
  version=$(status "$pod" | jq -r .version)
  if [[ $version != "$target" ]]; then
    echo "$pod runs $version, expected $target. Stopping." >&2
    exit 1
  fi
}

active=$(pods true)
standbys=$(pods false)
if [[ $(echo "$active" | wc -w) -ne 1 || $(echo "$standbys" | wc -w) -ne 2 ]]; then
  echo "Expected one active node and two standbys, found active: $active, standbys: $standbys" >&2
  exit 1
fi
echo "Active: $active. Standbys: $(echo $standbys)."

for pod in $standbys; do
  roll "$pod"
done
# The active node goes last. Deleting the pod shuts Vault down cleanly, so
# it hands the HA lock to an upgraded standby right away; no step-down.
roll "$active"

echo
echo "== done"
for pod in vault-0 vault-1 vault-2; do summary "$pod"; done
