# immich: log in with Scouts Online

foto.scoutingmbg.nl sits behind sol-auth, an Apache with mod_auth_openid
that lets any Scouting Nederland account through (OpenID 2, which Scouting
Nederland is phasing out). Behind it, people use two shared immich
accounts: `fotoupload@` owns all 45,703 photos and 504 albums, `foto@`
views them (its password is on the login page).

Goal: everyone logs in with their own Scouts Online 3 account and gets an
immich account of their own; kaderleden can upload, everyone else can only
view, and everything is shared with everyone automatically.

## Building blocks

- **Scouts Online 3** (login.scouting.nl) is an OIDC provider. A connection
  is registered under "Beheerde websites" by someone with the Webmaster
  role in SOL 3, and only members of the organisations picked there can
  log in. The `roles` scope returns the member's organisation units
  (`Board`, `Game Section` with speltak, committees, ...), roles
  (`member_type` `Jeugdlid`/`Kaderlid`, a category such as
  `Leidinggevende`) and role assignments with start and end dates, only
  from the userinfo endpoint and nested (https://login.scouting.nl/docs/api).
- **immich** can't read that: it takes the claims `immich_quota` (GiB; `0`
  blocks uploads, `-1` is unlimited) and `immich_role` (`user`/`admin`)
  and syncs both on every login. It links an OAuth login to an existing
  account by email, or creates one (auto register).
- **immich has no user groups**; albums are shared per user, as viewer or
  editor. The owner and editors of an album may add users and change
  their roles. Search only covers your own photos and those of partners
  you show in your timeline.

## Design

- **authentik** (on auth.scoutingmbg.nl, with a brand "Scouting MBG" that
  logs in through Scouts Online and then sends people to the photos)
  brokers the login: a
  Scouts Online source turns the roles into the groups `MBG leden` and
  `MBG kader` (active `Kaderlid` role) on every login, and the immich
  provider turns those into `immich_quota` and `immich_role`
  (`authentik/blueprint-scouting.yaml`). Members get `external` users;
  every personal app in this authentik is bound to `authentik Admins`.
- **immich** gets its settings from a config file rendered by ESO
  (`immich/immich-config.yaml`), OAuth with auto register and, after the
  switch, auto launch and no password login.
- **share-sync** (`immich/share-sync.yaml`), a CronJob every 10 minutes:
  every user into every album of the group account (`fotoupload@`), as
  editor or viewer by quota; the group account's library as a partner of
  everyone, shown in the timeline; album invitations for albums older than
  a week hidden; sessions of OAuth users older than 30 days ended. Albums
  that kaderleden create get the group account as editor first (in the
  database, since the API only lets an album's owner or editors share
  it), so they go to everyone too; names starting with "Privé"/"Prive"
  are skipped. Photos outside albums stay with their uploader.

## Steps

A. immich OAuth through authentik, next to the password login
- [x] Vault `kv/immich-oidc`: `client_secret` (random, e.g. `openssl rand -hex 32`)
- [x] Push the authentik and immich changes. Done 2026-10-24: both rolled
  over without downtime. authentik only found the new blueprint after
  `blueprints_discovery.send()` in `ak shell`; the claims came out as
  admin/-1 for authentik Admins, user/-1 for MBG kader, user/0 for MBG
  leden, and other users get no access
- [x] Test with an authentik admin account. The login created a new immich
  admin (`ik@rubenhensen.nl`, the authentik email) instead of linking the
  old one (`ruben.hensen@protonmail.com`): linking an existing account
  takes a password login first, then "Link to OAuth" in its settings

B. Scouts Online source
- [x] SOL connection, by someone with the Webmaster role: redirect URI
  `https://authentik.rubenhensen.nl/source/oauth/callback/scouts-online/`,
  post logout `https://foto.scoutingmbg.nl/`, scopes E-mail, Persoonlijk,
  Lidmaatschap, Rollen en lidmaatschappen; only the group, without
  sub-organisations; confidential client with PKCE required
- [x] Vault `kv/scouts-online`: `client_id`, `client_secret`
- [x] Source, enrollment and authentication flows, and a login flow that
  goes straight to Scouts Online (an identification stage with no fields
  and one source redirects on its own). Done 2026-10-24; the user mapping
  was tested beforehand with made-up userinfo (active and ended Kaderlid
  roles, a shared family email, no roles). A kaderlid's login made an
  external authentik user `sol-<member id>` in MBG leden and MBG kader, and
  an immich user with unlimited quota. Use a private window to test: an
  existing authentik session skips the login flow
- [ ] Test with a jeugdlid (quota 0, so no uploads)

C. Switch
- [x] Vault `kv/immich-share`: `api_key` of `fotoupload@` (album.read,
  albumUser.create, albumUser.update, partner.read, partner.create);
  share-sync dry run (`DRY_RUN=1`): 504 albums, no errors
- [x] Switched 2026-10-24 12:00 UTC: HTTPRoute straight to
  helm-immich-server (tested beforehand with a temporary route behind a
  secret header: page, API and a websocket upgrade), auto launch on,
  password login off, login page message gone, immich restarted to read
  the config file, the 25 sessions of `foto@` ended (those of
  `fotoupload@`, phones backing up to the group account, kept),
  share-sync on, gatus on s1 and s2 checking `/api/server/ping`. The first
  run hid no invitations: immich stores a notification's `data` as a JSON
  string inside the jsonb column; fixed, 1008 hidden, the 6 for albums of
  the last week kept
- [x] Removed sol-auth 2026-10-24 (`immich/sol-auth*`,
  `immich/httpd.conf-cm.yml`). The immich folder app doesn't prune, so its
  Deployment, Service and ConfigMap went through a sync limited to those
  three with prune on
- [x] `foto@`'s activity (155 likes, no comments) deleted 2026-10-24, and
  the account marked deleted the way immich's admin delete does (status
  `deleted`, `deletedAt`); immich removes it for good after 7 days
- [x] Nobody uses `fotoupload@` anymore: its 9 (browser) sessions ended
  2026-10-24. Its API key stays for share-sync

D. auth.scoutingmbg.nl (2026-10-25)
- [x] The group's DNS points scoutingmbg.nl, www, foto and auth at node001
  (rubenhensen.nl). node001 passes all four through to the home cluster
  (SNI on 443, a proxy on 80 for HTTP-01), like its other tunneled hosts,
  and gatus on s1 checks them
- [x] Certificate, Gateway listener `https-auth-scoutingmbg`, the authentik
  route on both hostnames, the brand, and immich's issuer on
  https://auth.scoutingmbg.nl/application/o/immich/
- [x] SOL connection: redirect URI
  `https://auth.scoutingmbg.nl/source/oauth/callback/scouts-online/`.
  Editing the connection left the authentik.rubenhensen.nl URI unusable
  (SOL answers `invalid_client` after the login when the redirect URI isn't
  registered), so logins failed for a few minutes until immich moved over

## Open points

- DNS (2026-10-24): the group's DNS host (ns1/ns2.webhosted.nl) changed
  foto.scoutingmbg.nl from a CNAME to `mbg.hensen.io` (the home IP) to a
  CNAME to `rubenhensen.nl`, which is node001 on Hetzner. Only ns2 has it
  (serial 2026102471); ns1 is stuck on serial 2026060640 from June and
  still answers `mbg.hensen.io`. node001 now tunnels foto.scoutingmbg.nl to
  the home cluster like its other hosts, so both answers work. Keep
  hensen.io until ns1 has caught up; ask the DNS host to fix ns1, and
  decide whether foto should stay behind node001 or point straight home
  (CNAME `scoutingmbg.nl`)
- Public shared links become public for real once sol-auth is gone.
- Photos leiding back up from their phones stay private until they add
  them to a shared album.
