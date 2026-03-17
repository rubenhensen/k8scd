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
        directory = "internal";
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

      authentication.fallback-admin = {
        user = "admin";
        secret = "%{file:/run/credentials/stalwart-mail.service/stalwart-admin-password}%";
      };
    };
  };

  systemd.services.stalwart-mail.serviceConfig.LoadCredentialEncrypted = [
    "stalwart-admin-password:/root/secrets/[%%secrets/stalwart-admin-password%%]"
  ];

  users.users.stalwart-mail.extraGroups = [ "acme" ];
}
