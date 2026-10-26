# Garage on the NAS

S3 storage for Velero, on the Synology (192.168.1.99) in Docker, outside
the cluster. Replaced MinIO, which is no longer maintained. One node, data
in `/volume1/docker/garage/{meta,data}`. S3 API on port 3900, admin API on
3903, both LAN only. Set up 2026-10-25 with Garage v2.5.0.

The NAS is reached as `ssh -p 34000 rubenhensen@192.168.1.99`; docker is
in `/usr/local/bin`, which a non-interactive SSH session doesn't have on
its PATH.

## Setup

`garage.toml` here has placeholders for the two secrets; on the NAS they
were filled in once with `openssl rand -hex 32` (`rpc_secret`) and
`openssl rand -base64 32` (`admin_token`), and only exist there.

```
cd /volume1/docker/garage
docker compose up -d
g="docker exec garage /garage"
$g layout assign -z nas -c 800G <node id from $g status>
$g layout apply --version 1
$g bucket create velero-backups
$g key create velero
$g bucket allow --read --write --key velero velero-backups
```

Velero's key is in Vault as `kv/velero-s3` (`access_key_id`,
`secret_access_key`) and reaches Velero through
`velero/external-secret.yaml`. Without the cluster, `$g key info velero
--show-secret` on the NAS shows it again.

CNPG's backups (`authentik/postgresql-backup.yaml`,
`immich/postgresql-backup.yaml`) have a bucket and a key per cluster, so
neither database can touch the other's backups. Made on 2026-10-26 the
same way as Velero's, with `cnpg-authentik` and `cnpg-immich` as both
bucket and key name; the keys are in Vault as `kv/cnpg-authentik-s3` and
`kv/cnpg-immich-s3`.

Renovate updates the image tag in `compose.yaml`, but nothing deploys it:
after merging, `docker compose pull && docker compose up -d` on the NAS.
