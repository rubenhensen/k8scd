# Gatus

Two Gatus instances check the same endpoints from two places:

| Status page | Runs on | Config |
|---|---|---|
| https://s1.rubenhensen.nl | Hetzner (node001) | `nix-infra-machine/nodes/node001.nix` |
| https://s2.rubenhensen.nl | Home cluster | `gatus/config.yaml` (this folder) |

Each one also checks the other's `/health`. The s2 DNS record points straight
at the home IP instead of going through the Hetzner tunnel, so s2 stays
reachable when Hetzner is down.

The endpoint list exists twice, so a new service has to be added in both
places. s1 builds its list from `tunneledHosts`, so new tunneled hosts show up
there automatically. s2 needs them added by hand.

## Alerting

Each Gatus sends alerts to an ntfy instance on its own node:
`ntfy1.rubenhensen.nl` (Hetzner, node001.nix) and `ntfy2.rubenhensen.nl`
(home, `ntfy/` in this repo). Subscribe the phone app to topic `alerts` on
both servers, with the same login on each.

Only the watcher that sees a service from outside alerts on it:

- s1 alerts on everything that runs at home (all tunneled apps, Scouting MBG)
  and on s2.
- s2 alerts on mail and on s1.

An outage on either node still reaches you, through the other node's ntfy,
and you get one notification per outage instead of two. An alert fires after
3 failed checks in a row (about 3 minutes), and you get another notification
when the service recovers.

Both ntfy servers deny everything except the provisioned user. The
credentials are the same on both:

- Home: Vault `kv/ntfy` with `auth_users`, `auth_tokens` and `gatus_token`,
  pulled in by External Secrets.
- Hetzner: the nix-infra secrets `ntfy-auth-users`, `ntfy-auth-tokens` and
  `ntfy-gatus-token`.

## Reading the two pages

- s1 sees the homelab from outside, so trust it for homelab services. s2 sees
  Hetzner from outside, so trust it for mail and anything else on Hetzner.
- Every `*.rubenhensen.nl` app is tunneled Hetzner → home, so a Hetzner
  outage shows all of them as down on both pages. That is accurate: nobody
  can reach them then.
- If s1 and s2 disagree about an endpoint, the problem is the network path
  between one watcher and that service, not the service itself.
- Neither page has history for the time its own node was down.

## Later: one URL with self-hosted DNS failover

This is the plan for replacing s1/s2 with a single `status.rubenhensen.nl`
that always points at a watcher that's up, with no third party involved.

Hand `status.rubenhensen.nl` over to two nameservers we run ourselves, one per
node, both PowerDNS Authoritative. PowerDNS LUA records health-check
addresses and only return the healthy ones:

```
@  30  IN  LUA  A  "ifurlup('https://status.rubenhensen.nl/health', {{'46.224.26.65'}, {'62.41.86.27'}})"
```

The double braces make two groups. PowerDNS returns the first group that has
a healthy address, so Hetzner is primary and home is the fallback. Each
nameserver runs the check from its own location.

| Situation | Hetzner NS | Home NS | Visitors end up on |
|---|---|---|---|
| Both up | answers Hetzner | answers Hetzner | Hetzner |
| Hetzner down | dead | Hetzner check fails, answers home | home |
| Home down / home internet down | answers Hetzner | dead | Hetzner |
| Hetzner up, its Gatus broken | own check fails, answers home | answers home | home |

A node that goes down takes its nameserver down with it, so DNS resolvers
switch to the other nameserver. The two nodes never have to agree with each
other: the answer depends on what the internet can reach. The 30s TTL caps
how long clients keep a stale answer.

Steps:

1. Parent zone (`dns/domains/rubenhensen.nl.yaml`, synced to TransIP): add
   `status NS ns-hetzner.rubenhensen.nl.` and `status NS ns-home.rubenhensen.nl.`,
   plus A records for `ns-hetzner` (46.224.26.65) and `ns-home` (62.41.86.27).
   First check that TransIP accepts NS records for a subdomain.
2. Hetzner: run PowerDNS from node001.nix with `enable-lua-records=yes` and
   the bind backend. Use the same zone file as home. Open 53/udp and 53/tcp.
3. Home: run PowerDNS in the cluster with the same zone file, on 53/udp and
   53/tcp of the home IP (router port forward, and check how the cluster
   exposes UDP).
4. Both Gatus instances also serve `status.rubenhensen.nl`. On Hetzner, add the
   name to the SNI map, the same way as s1.
5. TLS: Hetzner gets its cert through HTTP-01 as usual. On Hetzner's :80 vhost
   for `status`, serve local ACME challenges and proxy the rest to the home
   cluster (`try_files $uri @home`). That way cert-manager's HTTP-01 also
   works while DNS points at Hetzner. When Hetzner is down, DNS points home
   and cert-manager reaches the home cluster directly.
6. Requirements: a static home IP (`homeIP` in node001.nix already assumes
   one), and port 53 open on both nodes.

After that, s1/s2 can be removed, or kept as direct links to each instance.
