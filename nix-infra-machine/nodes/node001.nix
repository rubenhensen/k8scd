{ config, pkgs, lib, ... }:
{
  # ──────────────────────────────────────────────
  # Firewall
  # ──────────────────────────────────────────────
  networking.firewall.allowedTCPPorts = [
    25    # SMTP
    465   # SMTP submissions (implicit TLS)
    587   # SMTP submission (STARTTLS)
    993   # IMAP (implicit TLS)
    443   # HTTPS (webadmin)
    80    # HTTP (ACME)
  ];

  # ──────────────────────────────────────────────
  # ACME / Let's Encrypt
  # ──────────────────────────────────────────────
  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@rubenhensen.nl";
    certs."stalwart.rubenhensen.nl" = {
      group = "stalwart-mail";
      reloadServices = [ "stalwart-mail" ];
      webroot = "/var/lib/acme/acme-challenge";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/acme/acme-challenge 0755 acme acme -"
  ];

  # Serve ACME challenges via nginx on port 80
  services.nginx = {
    enable = true;
    virtualHosts."stalwart.rubenhensen.nl" = {
      listen = [
        { addr = "0.0.0.0"; port = 80; }
        { addr = "[::]"; port = 80; }
      ];
      locations."/.well-known/acme-challenge/" = {
        root = "/var/lib/acme/acme-challenge";
      };
      locations."/" = {
        return = "301 https://$host$request_uri";
      };
    };
  };

  # ──────────────────────────────────────────────
  # Stalwart mail server
  # ──────────────────────────────────────────────
  services.stalwart-mail = {
    enable = true;
    settings = {
      server = {
        hostname = "stalwart.rubenhensen.nl";
        listener = {
          smtp = {
            bind = "[::]:25";
            protocol = "smtp";
          };
          submission = {
            bind = "[::]:587";
            protocol = "smtp";
          };
          submissions = {
            bind = "[::]:465";
            protocol = "smtp";
            tls.implicit = true;
          };
          imaptls = {
            bind = "[::]:993";
            protocol = "imap";
            tls.implicit = true;
          };
          https = {
            bind = "[::]:443";
            protocol = "http";
            tls.implicit = true;
          };
        };
      };

      certificate.default = {
        cert = "%{file:/var/lib/acme/stalwart.rubenhensen.nl/fullchain.pem}%";
        private-key = "%{file:/var/lib/acme/stalwart.rubenhensen.nl/key.pem}%";
      };

      storage = {
        data = "rocksdb";
        fts = "rocksdb";
        blob = "rocksdb";
        lookup = "rocksdb";
        directory = "authentik";
      };

      store.rocksdb = {
        type = "rocksdb";
        path = "/var/lib/stalwart-mail/data";
        compression = "lz4";
      };

      directory.internal = {
        type = "internal";
        store = "rocksdb";
      };

      tracer.stdout = {
        type = "stdout";
        level = "info";
        ansi = false;
        enable = true;
      };

      directory.authentik = {
        type = "ldap";
        url = "ldap://ldap.rubenhensen.nl:389";
        timeout = "30s";
        tls.enable = false;
        base-dn = "DC=ldap,DC=goauthentik,DC=io";

        bind.dn = "cn=ldapservice,ou=users,DC=ldap,DC=goauthentik,DC=io";
        bind.secret = "%{file:/run/credentials/stalwart-mail.service/ldap_bind_password}%";
        bind.auth.method = "lookup";

        filter = {
          name = "(&(objectClass=user)(|(cn=?)(mail=?)))";
          email = "(&(objectClass=user)(mail=?))";
        };

        attributes = {
          name = "cn";
          class = "objectClass";
          email = "mail";
          groups = "memberOf";
        };
      };

      signature."rsa" = {
        private-key = "%{file:/run/credentials/stalwart-mail.service/dkim-rsa.key}%";
        domain = "rubenhensen.nl";
        selector = "202603r2";
        headers = ["From" "To" "Cc" "Date" "Subject" "Message-ID" "Organization" "MIME-Version" "Content-Type" "In-Reply-To" "References" "List-Id"];
        algorithm = "rsa-sha-256";
        canonicalization = "relaxed/relaxed";
        expire = "10d";
        set-body-length = false;
        report = true;
      };

      signature."ed25519" = {
        private-key = "%{file:/run/credentials/stalwart-mail.service/dkim-ed25519.key}%";
        domain = "rubenhensen.nl";
        selector = "202603e2";
        headers = ["From" "To" "Cc" "Date" "Subject" "Message-ID" "Organization" "MIME-Version" "Content-Type" "In-Reply-To" "References" "List-Id"];
        algorithm = "ed25519-sha256";
        canonicalization = "relaxed/relaxed";
        set-body-length = false;
        report = false;
      };

      auth.dkim.sign = [
        { "if" = "listener != 'smtp'"; "then" = "['rsa', 'ed25519']"; }
        { "else" = false; }
      ];

      authentication.fallback-admin = {
        user = "admin";
        secret = "%{file:/run/credentials/stalwart-mail.service/stalwart-admin-password}%";
      };
    };
  };

  systemd.services.stalwart-mail.serviceConfig.LoadCredentialEncrypted = [
    "stalwart-admin-password:/root/secrets/[%%secrets/stalwart-admin-password%%]"
    "ldap_bind_password:/root/secrets/[%%secrets/ldap_bind_password%%]"
    "dkim-rsa.key:/root/secrets/[%%secrets/dkim-rsa.key%%]"
    "dkim-ed25519.key:/root/secrets/[%%secrets/dkim-ed25519.key%%]"
  ];

  users.users.stalwart-mail.extraGroups = [ "acme" ];
}
