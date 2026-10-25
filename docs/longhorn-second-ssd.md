# A second SSD for Longhorn

## Why

Root, the dqlite database, every Longhorn replica, container images and
emptyDirs all sit on one Apacer AS350 1TB, a DRAM-less 2.5" SATA SSD. When
something writes to it for minutes (Longhorn backups at 00:00, the Velero
backup at 01:00, kopia maintenance, image pulls), its write latency climbs
and dqlite, which syncs every commit, stalls for seconds. Controllers then
lose their leases and restart ("Still stalling after the VACUUM" in
docs/upgrade-k8s-1.33.md). Longer leases and throttled maintenance soften
that; moving Longhorn's data to its own NVMe SSD takes away most of the
writes dqlite competes with.

The alternative, moving dqlite to the new SSD, is less work in data but
not in risk: its directory lives under the microk8s snap's revision
directory, which snapd copies on every refresh, so a bind mount there is
fragile. Longhorn supports several disks per node and moves replicas
between them live.

## Hardware

- opti1 is a Dell OptiPlex 5060 (BIOS 1.29.0); the i5-8600T points to the
  Micro, but check the case. Every 5060 has one M.2 2280 slot that takes
  PCIe NVMe (Gen3 x4); Dell sells 2280 Gen3 x4 drives for the Micro. The
  only storage controller is the SATA AHCI one and no NVMe device is
  present, so the slot should be empty.
- Buy an M.2 2280 NVMe SSD **with a DRAM cache**, 2 TB. Gen4 drives work and
  run at Gen3 speed, which is plenty and cooler. Examples with DRAM:
  Samsung 990 Pro, WD Black SN850X, Kingston KC3000, Crucial T500. Avoid
  DRAM-less and QLC drives (WD SN770, Samsung 990 EVO, Crucial P3); they
  have the same weakness as the current SSD. In the Micro, skip a heatsink
  that doesn't fit under the cover.
- Size: Longhorn holds 339 GiB on disk now, of which 297 GiB is the immich
  library (126 GB in use inside the volume; the rest is snapshots, see
  below). Personal immich accounts will add uploads; volumes can be sized
  up to 551 GiB in total today. 2 TB leaves room; 1 TB would fit for now.

## Before: shrink what has to move

- [x] Delete stale snapshots. 188 snapshots hold 334 GiB, 214 GiB of it in
  snapshots from before October 2026, nearly all on immich-claim
  (pvc-75d269dd): a 72.5 GiB one from 2024-12-20, 71.3 GiB from
  2025-03-02, daily ones from 2025-03-13 to 03-20 (a recurring job that no
  longer exists), 56.6 GiB from 2026-01-20. The Longhorn backups on the NAS
  don't depend on them. Deleting a snapshot merges it into the next one,
  which writes a lot, so do this in a quiet hour, one volume at a time.
  Happened on 2026-10-24, from a Claude Code session at Ruben's request
  (the 45 snapshots from before October 2026, small volumes first): immich-claim's
  old snapshots were removed at 14:43 UTC and Longhorn merged them one
  after another, about 45 minutes each, until 23:15. For those 8.5 hours
  sda ran 250-440 writes/s and 200-400 reads/s at 6-20 ms per write on
  average, with "full" IO pressure at 45-75% (`~/iosample.log`); the
  instance manager wrote 2.3 TB and read 2.8 TB in 30 hours. What is left
  on immich-claim is one 233 GiB snapshot (`system-backup-0b7f8c6047294b36`,
  from the Longhorn system backup of 2026-10-22) that everything merged
  into; 148 snapshots hold 273 GiB across all volumes.
- [ ] Delete the snapshots the Longhorn system backups left behind: 116
  `system-backup-*` snapshots (one per volume for each system backup
  before an upgrade step on 2026-10-22 and 23) hold 258 GiB. The system
  backups on the NAS don't need them. The small volumes are cheap; on
  immich-claim the 233 GiB one is the base the rest merged into, so
  deleting it means hours of merging like on 2026-10-24: one night, or
  after the move to the NVMe drive. Then trim (next item); deleted files
  only free space once both are done. Next time, take system backups with
  the volume backup policy `disabled` when the nightly backups are fresh,
  so they create no snapshots
- [ ] Trim immich-claim's filesystem (Longhorn UI, volume, "Trim Filesystem")
  so blocks of deleted files are released.
- [ ] Fresh backups: let a nightly Longhorn and Velero backup run, plus a
  Longhorn system backup.
- [ ] Set Longhorn's `concurrent-replica-rebuild-per-node-limit` from 5 to 1
  for the move, so only one replica copies at a time. It is not in the
  Helm values, so set it in the UI (Settings, General) or with
  `kubectl -n longhorn-system patch settings.longhorn.io concurrent-replica-rebuild-per-node-limit --type merge -p '{"value":"1"}'`.

## Install (downtime: everything, about 15 minutes)

- [ ] `sudo shutdown -h now` on opti1. microk8s stops, the volumes detach.
- [ ] Unplug, open the case, put the SSD in the M.2 slot and screw it down.
- [ ] Boot into the BIOS (F2): the NVMe drive shows up under storage, SATA
  operation stays AHCI, and the boot sequence still starts "ubuntu" from
  the SATA SSD.
- [ ] Boot. `lsblk` shows `nvme0n1`.
- [ ] Unseal Vault, which comes up sealed (until then ESO can't refresh
  secrets): `for p in vault-0 vault-1 vault-2; do kubectl -n vault exec -ti $p -- vault operator unseal; done`
- [ ] Wait until everything is green again (gatus on s1 and s2).

## Prepare the disk (sudo on opti1)

```bash
lsblk -o NAME,SIZE,MODEL /dev/nvme0n1          # the new, empty drive
sudo wipefs -a /dev/nvme0n1
sudo parted -s /dev/nvme0n1 mklabel gpt mkpart longhorn ext4 1MiB 100%
sudo mkfs.ext4 -L longhorn-nvme /dev/nvme0n1p1
sudo mkdir -p /var/lib/longhorn-nvme
echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p1) /var/lib/longhorn-nvme ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /var/lib/longhorn-nvme
df -h /var/lib/longhorn-nvme
```

Longhorn wants an extent-based filesystem (ext4 or xfs) mounted at a
directory, no symlink. With `nofail` a missing drive doesn't block the
boot; Longhorn then sees an empty directory on the root filesystem with
the wrong filesystem ID and won't use it. Ubuntu's weekly `fstrim.timer`
covers the new filesystem too.

## Move Longhorn's data (no downtime)

- [ ] Add the disk to the Longhorn node:
  ```bash
  kubectl -n longhorn-system patch nodes.longhorn.io opti1 --type merge -p '{"spec":{"disks":{"nvme":{"path":"/var/lib/longhorn-nvme","diskType":"filesystem","allowScheduling":true,"evictionRequested":false,"storageReserved":53687091200,"tags":[]}}}}'
  ```
  (50 GiB reserved.) Wait until the disk is Ready and Schedulable.
- [ ] On the old disk (`default-disk-5db8685563bf9bf9`, `/var/lib/longhorn/`)
  set `allowScheduling: false`, then `evictionRequested: true`. Longhorn
  builds a new replica of each volume on the NVMe drive and drops the old
  one once the rebuild succeeds; it attaches detached volumes for this
  itself. All 20 volumes have one replica, so each briefly has two.
- [ ] Watch the old disk's replica count go to 0 (UI, Node, or
  `kubectl -n longhorn-system get nodes.longhorn.io opti1 -o yaml`). The
  immich library takes longest. Copying reads from the SATA SSD, so expect
  a few slow API moments meanwhile; best in the evening.
- [ ] Remove the old disk from `spec.disks` once it has no replicas, and set
  the rebuild limit back to 5.

To stop halfway: set `evictionRequested` back to false; replicas already
moved stay on the NVMe drive, the rest on the SATA SSD, and both disks
work.

## Afterwards

- [ ] Compare with before: lease updates over 5s
  (`apiserver_request_duration_seconds` for PUT on leases), controller
  restarts, and sda's latency during the nightly backups
  (`~/iosample.sh`).
- [ ] Optional, if stalls remain: container images
  (`/var/snap/microk8s/common/var/lib/containerd`) and the kubelet's
  emptyDirs, such as kopia's scratch space, still write to the SATA SSD.

## Sources

- Dell parts for the OptiPlex 5060 Micro, with M.2 2280 PCIe NVMe Gen3 x4
  drives: https://dell.com/en-au/shop/pfydresults/6163895
- Longhorn, eviction: https://longhorn.io/docs/1.13.0/nodes-and-volumes/nodes/disks-or-nodes-eviction/
- Longhorn, multiple disks: https://longhorn.io/docs/1.13.0/nodes-and-volumes/nodes/multidisk/
