{ config, pkgs, lib, ... }:
let
  # Public IP of the home network where the k8s cluster ingress lives.
  # Keep in sync with dns/domains/rubenhensen.nl.yaml.
  homeIP = "62.41.87.114";
in
{
  # ──────────────────────────────────────────────
  # Firewall
  # ──────────────────────────────────────────────
  networking.firewall.allowedTCPPorts = [
    25    # SMTP
    465   # SMTP submissions (implicit TLS)
    587   # SMTP submission (STARTTLS)
    993   # IMAP (implicit TLS)
    4190  # ManageSieve
    443   # HTTPS (webadmin)
    80    # HTTP (ACME)
  ];

  # ──────────────────────────────────────────────
  # ACME / Let's Encrypt
  # ──────────────────────────────────────────────
  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@rubenhensen.nl";
    certs."mail.rubenhensen.nl" = {
      group = "stalwart-mail";
      reloadServices = [ "stalwart-mail" ];
      webroot = "/var/lib/acme/acme-challenge";
      extraDomainNames = [
        "autoconfig.rubenhensen.nl"
        "autodiscover.rubenhensen.nl"
        "rubenhensen.nl"
      ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/acme/acme-challenge 0755 acme acme -"
  ];

  # Serve ACME challenges via nginx on port 80.
  # Also reverse-proxy tunneled hosts to the home k8s cluster, and do
  # SNI-based TCP passthrough on 443 so the cluster's cert-manager keeps
  # owning the TLS certificate for those hosts.
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;

    # SNI passthrough on 443:
    #   - mail.rubenhensen.nl (and anything else) → local stalwart on 8443
    #   - tunneled hosts → home cluster ingress on 443
    streamConfig = ''
      map $ssl_preread_server_name $tunnel_upstream {
        rss.rubenhensen.nl        ${homeIP}:443;
        authentik.rubenhensen.nl  ${homeIP}:443;
        vault.rubenhensen.nl      ${homeIP}:443;
        ynab.rubenhensen.nl       ${homeIP}:443;
        default                   127.0.0.1:8443;
      }

      server {
        listen 443;
        listen [::]:443;
        proxy_pass $tunnel_upstream;
        ssl_preread on;
      }
    '';

    # Tunneled hosts: forward plain HTTP to the home cluster so the
    # cluster's nginx-ingress handles HTTP→HTTPS redirects and
    # cert-manager HTTP-01 ACME challenges.
    virtualHosts."rss.rubenhensen.nl" = {
      listen = [
        { addr = "0.0.0.0"; port = 80; }
        { addr = "[::]"; port = 80; }
      ];
      locations."/" = {
        proxyPass = "http://${homeIP}";
      };
    };

    virtualHosts."authentik.rubenhensen.nl" = {
      listen = [
        { addr = "0.0.0.0"; port = 80; }
        { addr = "[::]"; port = 80; }
      ];
      locations."/" = {
        proxyPass = "http://${homeIP}";
      };
    };

    virtualHosts."vault.rubenhensen.nl" = {
      listen = [
        { addr = "0.0.0.0"; port = 80; }
        { addr = "[::]"; port = 80; }
      ];
      locations."/" = {
        proxyPass = "http://${homeIP}";
      };
    };

    virtualHosts."ynab.rubenhensen.nl" = {
      listen = [
        { addr = "0.0.0.0"; port = 80; }
        { addr = "[::]"; port = 80; }
      ];
      locations."/" = {
        proxyPass = "http://${homeIP}";
      };
    };

    virtualHosts."mail.rubenhensen.nl" = {
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
    virtualHosts."autoconfig.rubenhensen.nl" = {
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
    virtualHosts."autodiscover.rubenhensen.nl" = {
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
    virtualHosts."rubenhensen.nl" = {
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
        hostname = "mail.rubenhensen.nl";
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
          managesieve = {
            bind = "[::]:4190";
            protocol = "managesieve";
          };
          https = {
            # nginx owns the public :443 and does SNI passthrough to here
            # for the mail.rubenhensen.nl SNI. Stalwart still terminates TLS.
            bind = "127.0.0.1:8443";
            protocol = "http";
            tls.implicit = true;
          };
        };
      };

      certificate.default = {
        cert = "%{file:/var/lib/acme/mail.rubenhensen.nl/fullchain.pem}%";
        private-key = "%{file:/var/lib/acme/mail.rubenhensen.nl/key.pem}%";
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

      oauth.oidc = {
        issuer-url = "https://authentik.rubenhensen.nl/application/o/stalwart/";
        client-id = "%{file:/run/credentials/stalwart-mail.service/oidc-client-id}%";
        client-secret = "%{file:/run/credentials/stalwart-mail.service/oidc-client-secret}%";
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
    "oidc-client-id:/root/secrets/[%%secrets/oidc-client-id%%]"
    "oidc-client-secret:/root/secrets/[%%secrets/oidc-client-secret%%]"
    "dkim-rsa.key:/root/secrets/[%%secrets/dkim-rsa.key%%]"
    "dkim-ed25519.key:/root/secrets/[%%secrets/dkim-ed25519.key%%]"
  ];

  users.users.stalwart-mail.extraGroups = [ "acme" ];
}
