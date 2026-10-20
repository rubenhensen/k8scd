{ config, pkgs, lib, ... }:
let
  # Public IP of the home network where the k8s cluster ingress lives.
  # Keep in sync with dns/domains/rubenhensen.nl.yaml.
  homeIP = "62.41.86.27";

  # Hosts tunneled to the home k8s cluster. Each entry gets:
  #   * an SNI map entry for TCP passthrough on :443
  #   * an HTTP vhost on :80 that reverse-proxies to the cluster
  # The cluster's nginx-ingress terminates TLS with cert-manager.
  tunneledHosts = [
    "rss.rubenhensen.nl"
    "authentik.rubenhensen.nl"
    "vault.rubenhensen.nl"
    "ynab.rubenhensen.nl"
    "argocd.rubenhensen.nl"
    "ha.rubenhensen.nl"
    "longhorn.rubenhensen.nl"
    "lingo.rubenhensen.nl"
    "blog.rubenhensen.nl"
    "serpbear.rubenhensen.nl"
    "git.rubenhensen.nl"
    "vic.rubenhensen.nl"
  ];

  sniMapEntries =
    lib.concatMapStringsSep "\n"
      (h: "        ${h} ${homeIP}:443;")
      tunneledHosts;

  tunneledVhosts = lib.listToAttrs (map (h: {
    name = h;
    value = {
      listen = [
        { addr = "0.0.0.0"; port = 80; }
        { addr = "[::]"; port = 80; }
      ];
      locations."/".proxyPass = "http://${homeIP}";
    };
  }) tunneledHosts);

  # Gatus endpoints for s1.rubenhensen.nl. Its twin s2.rubenhensen.nl runs
  # on the home cluster with the same list, see gatus/config.yaml in k8scd.
  # Keep the two in sync.
  gatusHttp = group: name: url: {
    inherit name group url;
    interval = "60s";
    conditions = [
      "[STATUS] == 200"
      "[CERTIFICATE_EXPIRATION] > 168h"
    ];
  };

  # Per-host tweaks on top of the default check.
  gatusOverrides = {
    # Behind basic auth, so 401 means it's up
    "longhorn.rubenhensen.nl".conditions = [
      "[STATUS] == 401"
      "[CERTIFICATE_EXPIRATION] > 168h"
    ];
    # mod_auth_openidc answers 401 instead of redirecting to the login
    # page unless the client asks for HTML
    "rss.rubenhensen.nl".headers.Accept = "text/html";
  };

  # s1 is the outside view of home, so it alerts on what runs there and on
  # s2. Mail lives on this box, so s2 alerts on that.
  gatusAlert = { alerts = [ { type = "ntfy"; } ]; };

  gatusEndpoints =
    map (h:
      gatusHttp "rubenhensen.nl" (lib.removeSuffix ".rubenhensen.nl" h) "https://${h}"
      // gatusAlert
      // (gatusOverrides.${h} or { })) tunneledHosts
    ++ [
      (gatusHttp "mail" "webmail" "https://mail.rubenhensen.nl")
      {
        name = "smtp";
        group = "mail";
        url = "tcp://mail.rubenhensen.nl:25";
        interval = "60s";
        conditions = [ "[CONNECTED] == true" ];
      }
      {
        name = "imaps";
        group = "mail";
        url = "tls://mail.rubenhensen.nl:993";
        interval = "60s";
        conditions = [ "[CONNECTED] == true" "[CERTIFICATE_EXPIRATION] > 168h" ];
      }
      (gatusHttp "Scouting MBG" "scoutingmbg.nl" "https://scoutingmbg.nl" // gatusAlert)
      (gatusHttp "Scouting MBG" "foto.scoutingmbg.nl" "https://foto.scoutingmbg.nl/_app" // gatusAlert)
      ({
        name = "s2 (homelab)";
        group = "watchers";
        url = "https://s2.rubenhensen.nl/health";
        interval = "60s";
        conditions = [ "[STATUS] == 200" "[BODY].status == UP" ];
      } // gatusAlert)
    ];

  # Runs a service with secrets from LoadCredentialEncrypted exported as
  # env vars, for services that only take secrets through the environment.
  withCredentialEnv = name: vars: cmd: pkgs.writeShellScript "${name}-with-credentials" ''
    ${lib.concatStrings (lib.mapAttrsToList (var: cred: ''
      export ${var}="$(cat "$CREDENTIALS_DIRECTORY/${cred}")"
    '') vars)}
    exec ${cmd}
  '';
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
    #   - s1 / ntfy1.rubenhensen.nl → local nginx on 8444 (Gatus, ntfy)
    streamConfig = ''
      map $ssl_preread_server_name $tunnel_upstream {
${sniMapEntries}
        s1.rubenhensen.nl 127.0.0.1:8444;
        ntfy1.rubenhensen.nl 127.0.0.1:8444;
        default 127.0.0.1:8443;
      }

      server {
        listen 443;
        listen [::]:443;
        proxy_pass $tunnel_upstream;
        ssl_preread on;
      }
    '';

    # Port 80: tunneled hosts reverse-proxy to the home cluster so its
    # nginx-ingress handles HTTP→HTTPS redirects and cert-manager
    # HTTP-01 ACME challenges. Mail-related hosts serve ACME challenges
    # locally for stalwart's cert and redirect everything else to HTTPS.
    virtualHosts = tunneledVhosts // {
      "mail.rubenhensen.nl" = {
        listen = [
          { addr = "0.0.0.0"; port = 80; }
          { addr = "[::]"; port = 80; }
        ];
        locations."/.well-known/acme-challenge/".root = "/var/lib/acme/acme-challenge";
        locations."/".return = "301 https://$host$request_uri";
      };
      "autoconfig.rubenhensen.nl" = {
        listen = [
          { addr = "0.0.0.0"; port = 80; }
          { addr = "[::]"; port = 80; }
        ];
        locations."/.well-known/acme-challenge/".root = "/var/lib/acme/acme-challenge";
        locations."/".return = "301 https://$host$request_uri";
      };
      "autodiscover.rubenhensen.nl" = {
        listen = [
          { addr = "0.0.0.0"; port = 80; }
          { addr = "[::]"; port = 80; }
        ];
        locations."/.well-known/acme-challenge/".root = "/var/lib/acme/acme-challenge";
        locations."/".return = "301 https://$host$request_uri";
      };
      "rubenhensen.nl" = {
        listen = [
          { addr = "0.0.0.0"; port = 80; }
          { addr = "[::]"; port = 80; }
        ];
        locations."/.well-known/acme-challenge/".root = "/var/lib/acme/acme-challenge";
        locations."/".return = "301 https://$host$request_uri";
      };
      # Gatus status page. The stream block above passes its SNI to
      # 8444, where nginx terminates TLS with its own ACME cert.
      "s1.rubenhensen.nl" = {
        listen = [
          { addr = "0.0.0.0"; port = 80; }
          { addr = "[::]"; port = 80; }
          { addr = "127.0.0.1"; port = 8444; ssl = true; }
        ];
        enableACME = true;
        forceSSL = true;
        locations."/".proxyPass = "http://127.0.0.1:8090";
      };
      # ntfy for Gatus alerts, same TLS setup as s1. Proxy settings follow
      # the ntfy docs so subscriptions can stay open.
      "ntfy1.rubenhensen.nl" = {
        listen = [
          { addr = "0.0.0.0"; port = 80; }
          { addr = "[::]"; port = 80; }
          { addr = "127.0.0.1"; port = 8444; ssl = true; }
        ];
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:2586";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_connect_timeout 3m;
            proxy_send_timeout 3m;
            proxy_read_timeout 3m;
            client_max_body_size 0;
          '';
        };
      };
    };
  };

  # ──────────────────────────────────────────────
  # ntfy (ntfy1.rubenhensen.nl)
  # ──────────────────────────────────────────────
  # Users and tokens come from secrets, everything else is denied. The
  # same login works on ntfy2.rubenhensen.nl at home.
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy1.rubenhensen.nl";
      listen-http = "127.0.0.1:2586";
      behind-proxy = true;
      auth-file = "/var/lib/ntfy-sh/user.db";
      auth-default-access = "deny-all";
      cache-file = "/var/lib/ntfy-sh/cache.db";
      # Needed for instant delivery on iOS. ntfy.sh only gets the message
      # ID, never the content.
      upstream-base-url = "https://ntfy.sh";
    };
  };

  systemd.services.ntfy-sh.serviceConfig = {
    LoadCredentialEncrypted = [
      "ntfy-auth-users:/root/secrets/[%%secrets/ntfy-auth-users%%]"
      "ntfy-auth-tokens:/root/secrets/[%%secrets/ntfy-auth-tokens%%]"
    ];
    ExecStart = lib.mkForce (withCredentialEnv "ntfy-sh" {
      NTFY_AUTH_USERS = "ntfy-auth-users";
      NTFY_AUTH_TOKENS = "ntfy-auth-tokens";
    } "${config.services.ntfy-sh.package}/bin/ntfy serve -c /etc/ntfy/server.yml");
  };

  # ──────────────────────────────────────────────
  # Gatus (s1.rubenhensen.nl)
  # ──────────────────────────────────────────────
  services.gatus = {
    enable = true;
    settings = {
      web = {
        address = "127.0.0.1";
        port = 8090;
      };
      storage = {
        type = "sqlite";
        path = "/var/lib/gatus/data.db";
      };
      ui = {
        title = "Status (Hetzner)";
        header = "s1 · Hetzner";
        buttons = [
          { name = "s2 (homelab)"; link = "https://s2.rubenhensen.nl"; }
        ];
      };
      alerting.ntfy = {
        url = "http://127.0.0.1:2586";
        topic = "alerts";
        token = "\${NTFY_TOKEN}";
        priority = 4;
        click = "https://s1.rubenhensen.nl";
        default-alert = {
          failure-threshold = 3;
          success-threshold = 2;
          send-on-resolved = true;
        };
      };
      endpoints = gatusEndpoints;
    };
  };

  systemd.services.gatus = {
    after = [ "ntfy-sh.service" ];
    serviceConfig = {
      LoadCredentialEncrypted = [
        "ntfy-gatus-token:/root/secrets/[%%secrets/ntfy-gatus-token%%]"
      ];
      ExecStart = lib.mkForce (withCredentialEnv "gatus" {
        NTFY_TOKEN = "ntfy-gatus-token";
      } (lib.getExe config.services.gatus.package));
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
