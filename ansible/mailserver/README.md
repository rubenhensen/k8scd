# Mailserver Ansible

Ansible playbook that deploys and hardens a [Stalwart](https://stalw.art) all-in-one mail server on Ubuntu.

## What it does

| Role | Purpose |
|------|---------|
| `base` | apt upgrades, unattended-upgrades, timezone, swap, sysctl hardening |
| `ssh` | Key-only root login, disable password auth, rate limiting |
| `ufw` | Firewall — deny all incoming except SSH, SMTP, IMAP, HTTPS |
| `fail2ban` | Brute force protection for SSH + Stalwart auth |
| `stalwart` | Stalwart mail server with built-in ACME (Let's Encrypt) |

## Prerequisites

- Ubuntu server with root SSH key access
- DNS: `mail.rubenhensen.nl` → server IP (A record)
- DNS: MX record for your domain pointing to `mail.rubenhensen.nl`
- Ansible installed locally (`brew install ansible`)

## Setup

```bash
cd ~/Repos/k8scd/ansible/mailserver

# 1. Create vault password file (gitignored)
echo 'your-vault-password' > .vault_pass
chmod 600 .vault_pass

# 2. Create encrypted secrets
ansible-vault create host_vars/mailserver/vault.yml
# Add:
#   ---
#   vault_stalwart_fallback_admin_password: "your-admin-password"

# 3. Edit inventory if server IP changed
#    inventory.yml → ansible_host

# 4. Run
ansible-playbook playbook.yml
```

## Day-to-day operations

**Re-run after config changes:**
```bash
ansible-playbook playbook.yml
```

**Edit encrypted secrets:**
```bash
ansible-vault edit host_vars/mailserver/vault.yml
```

**Run only a specific role:**
```bash
ansible-playbook playbook.yml --tags stalwart
```
(Note: tags aren't configured yet — use `--start-at-task "task name"` or add tags if needed)

**Upgrade Stalwart:**
Bump `stalwart_version` in `roles/stalwart/defaults/main.yml` and re-run. It only re-downloads when the version changes.

## File structure

```
├── ansible.cfg              # Ansible settings + vault password file path
├── inventory.yml            # Server IP, SSH user, python interpreter
├── .vault_pass              # Vault password (gitignored)
├── .gitignore
├── host_vars/mailserver/
│   ├── vars.yml             # Maps variables to vault references
│   └── vault.yml            # Encrypted secrets (committed as ciphertext)
└── roles/
    ├── base/                # OS hardening + swap
    ├── ssh/                 # sshd_config template
    ├── ufw/                 # Firewall rules
    ├── fail2ban/            # Jails for SSH + Stalwart
    └── stalwart/            # Mail server install + config.toml template
```

## Stalwart admin

Web admin: `https://mail.rubenhensen.nl`
Login: `admin` / (password from vault)

From the web UI you can manage domains, accounts, DKIM keys, and other mail settings.

## TLS certificates

Handled automatically by Stalwart's built-in ACME support (Let's Encrypt, `tls-alpn-01` challenge on port 443). No certbot needed. Certificates auto-renew.

## Ports

| Port | Service |
|------|---------|
| 22 | SSH |
| 25 | SMTP |
| 465 | SMTP submission (implicit TLS) |
| 587 | SMTP submission (STARTTLS) |
| 993 | IMAP (implicit TLS) |
| 443 | HTTPS (web admin + JMAP + ACME) |
| 8080 | HTTP |

## If something breaks

- Stalwart logs: `/opt/stalwart/logs/`
- Stalwart config: `/opt/stalwart/etc/config.toml`
- Service status: `systemctl status stalwart`
- fail2ban status: `fail2ban-client status` / `fail2ban-client status sshd`
- Firewall: `ufw status`
- Check banned IPs: `fail2ban-client status stalwart-auth`
- Unban an IP: `fail2ban-client set <jail> unbanip <ip>`
