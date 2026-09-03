# Authentik

Authentik is deployed as the central identity provider, providing OIDC and LDAP authentication for services in the cluster.

## Components

- **Authentik Server** — Helm chart deployment (`apps/templates/authentik-helm.yaml`)
- **PostgreSQL** — CloudNativePG cluster (`postgresql-cluster.yaml`)
- **Secrets** — ExternalSecrets from Vault (`external-secret.yaml`)
- **Blueprints** — Auto-configured providers:
  - `blueprint-ldap.yaml` — LDAP provider (base DN: `DC=ldap,DC=goauthentik,DC=io`)
  - `blueprint-mail-oidc.yaml` — OAuth2/OIDC provider for Stalwart mail
  - `blueprint-vault-oidc.yaml` — OIDC provider for Vault
  - `blueprint-argocd-oidc.yaml` — OIDC provider for ArgoCD
  - `blueprint-freshrss-oidc.yaml` — OIDC provider for FreshRSS
  - `blueprint-actualbudget-proxy.yaml` — Proxy provider for Actual Budget
  - `blueprint-session-duration.yaml` — Session lifetime of the default authentication flow

## Session lifetime

Authentik ships the login stage of `default-authentication-flow` with
`session_duration: seconds=0`, i.e. the SSO session dies when the browser closes.
`blueprint-session-duration.yaml` raises this to 30 days for every app that uses
that flow (FreshRSS, ArgoCD, Vault, Actual Budget, mail).

The expiry is **absolute** — Authentik does not extend a session on activity. A
sliding window has to come from the application itself; FreshRSS does this via
`OIDC_SESSION_INACTIVITY_TIMEOUT` (see `freshrss/freshrss-deployment.yaml`), which
Apache mod_auth_openidc refreshes on every request.

## LDAP Outpost

The LDAP outpost exposes Authentik's user directory over LDAP. It is used by:
- **SOGo-mail** (in-cluster) — connects via `ak-outpost-ldap-outpost.authentik.svc.cluster.local:3389`
- **Stalwart** (NixOS, external) — connects via `ldap.rubenhensen.nl:389`

### NodePort Service

The outpost is exposed externally via a NodePort service (`ldap-outpost-lb.yaml`):
- LDAP: `389 → 3389` (NodePort `30389`)
- LDAPS: `636 → 6636` (NodePort `30636`)

The router port-forwards `389 → 30389` on the cluster node to make it reachable at `ldap.rubenhensen.nl`.

**Important:** The pod selector is `app.kubernetes.io/name: authentik-outpost-ldap` (set by Authentik's outpost controller, not the outpost name).

### MicroK8s CA Certificate Fix

Authentik's outpost controller needs to talk to the Kubernetes API to deploy the LDAP outpost pod. This fails on MicroK8s because the default CA certificate is missing the `keyUsage` extension, which Python 3.13+ enforces strictly.

**Error:**
```
SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
CA cert does not include key usage extension (_ssl.c:1081)
```

**Root cause:** https://github.com/canonical/microk8s/issues/4864

**Fix applied (2026-03-21):** Regenerated the MicroK8s CA certificate with the `keyUsage` extension using the script from the issue above:

```bash
#!/bin/bash
set -euo pipefail

cert_workspace="$HOME/fixed-certs"
mkdir -p "$cert_workspace"
cd "$cert_workspace"

# Generate new CA key
openssl genrsa -out ca.key 2048

# Generate CA cert WITH keyUsage extension
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -out ca.crt \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -subj "/CN=microk8s-ca"

# Verify the certificate has the extension
openssl x509 -in ca.crt -text -noout | grep -A 1 "Key Usage"

# Rotate the cluster CA
microk8s refresh-certs "$cert_workspace"

# Regenerate kubeconfig
mkdir -p ~/.kube
microk8s config > ~/.kube/config
```

**Note:** This must be re-applied after MicroK8s upgrades or cert rotations, as MicroK8s may regenerate the CA without the extension. The fix needs to run on every node in the cluster.
