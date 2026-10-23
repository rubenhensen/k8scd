#!/bin/bash
# VACUUM the k8s-dqlite database, see "Shrink the database" in
# docs/upgrade-k8s-1.33.md. Copy this script and the tool next to it to the
# home directory on opti1; build the tool with
#   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o dqlite-vacuum .
#
# Rehearsed on a throwaway node with the binaries of microk8s 1.34: 657 MB to
# 41 MB in 0.6s, writes next to it kept working, and the data was intact
# after a restart and after the first snapshot.
#
# To go back to the state before the VACUUM:
#   sudo snap stop microk8s.daemon-k8s-dqlite
#   cd /var/snap/microk8s/current/var/kubernetes
#   sudo mv backend backend.vacuumed && sudo tar -xpf /root/backend-pre-vacuum-<stamp>.tar
#   sudo snap start microk8s.daemon-k8s-dqlite
set -euo pipefail
stamp=$(date +%Y%m%d-%H%M)
kube=/var/snap/microk8s/current/var/kubernetes
shell="/snap/microk8s/current/bin/dqlite -s 127.0.0.1:19001 -c $kube/backend/cluster.crt -k $kube/backend/cluster.key --timeout 60000 k8s"
echo "== $(date) start"

echo "== datastore backup to /root/dqlite-pre-vacuum-$stamp.tar.gz"
sudo microk8s dbctl backup -o /root/dqlite-pre-vacuum-$stamp

echo "== offline copy of the backend (API down ~1 min, pods keep running)"
sudo snap stop microk8s.daemon-k8s-dqlite
sudo tar -cpf /root/backend-pre-vacuum-$stamp.tar -C $kube backend
sudo snap start microk8s.daemon-k8s-dqlite
sudo ls -la /root/backend-pre-vacuum-$stamp.tar /root/dqlite-pre-vacuum-$stamp.tar.gz
sudo microk8s status --wait-ready --timeout 300 >/dev/null && echo "microk8s is ready"
echo "== letting the API server and controllers settle for a minute"
sleep 60

echo "== VACUUM"
ps -o rss= -C k8s-dqlite | awk '{printf "k8s-dqlite RSS before: %.0f MB\n", $1/1024}'
~/dqlite-vacuum -vacuum
echo "== integrity check"
$shell "PRAGMA integrity_check"
ps -o rss= -C k8s-dqlite | awk '{printf "k8s-dqlite RSS after: %.0f MB\n", $1/1024}'
echo "== $(date) done"
