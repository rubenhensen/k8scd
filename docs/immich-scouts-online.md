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

- **authentik** (authentik.rubenhensen.nl for now; auth.scoutingmbg.nl
  later, once the group's DNS has a record for it) brokers the login: a
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
  that leiding create themselves are included once they share them with
  the group account as editor.

## Steps

A. immich OAuth through authentik, next to the password login
- [ ] Vault `kv/immich-oidc`: `client_secret` (random, e.g. `openssl rand -hex 32`)
- [ ] Push the authentik and immich changes (authentik restarts once for the
  new mounts, immich once for the config file)
- [ ] Test with an authentik admin account: "Link to OAuth" in immich's
  account settings for the existing admin

B. Scouts Online source
- [ ] SOL connection, by someone with the Webmaster role: redirect URI
  `https://authentik.rubenhensen.nl/source/oauth/callback/scouts-online/`,
  post logout `https://foto.scoutingmbg.nl/`, scopes E-mail, Persoonlijk,
  Lidmaatschap, Rollen en lidmaatschappen; only the group, without
  sub-organisations; confidential client with PKCE required
- [ ] Vault `kv/scouts-online`: `client_id`, `client_secret`
- [ ] Source, enrollment and authentication flows, and a login flow that
  goes straight to Scouts Online (an identification stage with no fields
  and one source redirects on its own); test with a kaderlid and a jeugdlid

C. Switch
- [ ] Vault `kv/immich-share`: `api_key` of `fotoupload@` (album.read,
  albumUser.create, albumUser.update, partner.read, partner.create);
  share-sync dry run (`DRY_RUN=1`)
- [ ] HTTPRoute straight to helm-immich-server, auto launch on, password
  login off, login page message gone, `foto@` disabled, share-sync on
- [ ] Remove sol-auth (`immich/sol-auth*`, `immich/httpd.conf-cm.yml`)

## Open points

- `foto.scoutingmbg.nl` is a CNAME to `mbg.hensen.io`; hensen.io is about
  to expire. Keep it until the group's DNS points foto at scoutingmbg.nl.
- Public shared links become public for real once sol-auth is gone.
- Photos leiding back up from their phones stay private until they add
  them to a shared album.
