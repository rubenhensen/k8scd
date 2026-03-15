{ config, pkgs, lib, ... }:
let
  k8sUpstreamConf = "/run/nginx/k8s-upstream.conf";
  k8sHttpUpstreamConf = "/run/nginx/k8s-http-upstream.conf";

  updateK8sIp = pkgs.writeShellScriptBin "update-k8s-ip" ''
    NEW_IP="$SSH_ORIGINAL_COMMAND"

    if ! echo "$NEW_IP" | ${pkgs.gnugrep}/bin/grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "Invalid IP: $NEW_IP"
        exit 1
    fi

    CONF="${k8sUpstreamConf}"
    CURRENT_IP=$(${pkgs.gnugrep}/bin/grep -oP 'server \K[0-9.]+' "$CONF" 2>/dev/null | head -1)

    if [ "$CURRENT_IP" = "$NEW_IP" ]; then
        echo "IP unchanged: $NEW_IP"
        exit 0
    fi

    printf 'upstream k8s_tls {\n    server %s:443;\n}\n\nupstream k8s_ldap {\n    server %s:3389;\n}\n' "$NEW_IP" "$NEW_IP" > "$CONF"
    printf 'upstream k8s_http {\n    server %s:80;\n}\n' "$NEW_IP" > ${k8sHttpUpstreamConf}

    ${pkgs.nginx}/bin/nginx -t && ${pkgs.systemd}/bin/systemctl reload nginx
    echo "Updated K8s backend IP to $NEW_IP"
  '';
in
{
  # ──────────────────────────────────────────────
  # Firewall (replaces UFW)
  # ──────────────────────────────────────────────
  networking.firewall.allowedTCPPorts = [
    25    # SMTP
    465   # SMTP submissions (implicit TLS)
    587   # SMTP submission (STARTTLS)
    993   # IMAP (implicit TLS)
    443   # HTTPS
    80    # HTTP (ACME + redirect)
  ];

  # ──────────────────────────────────────────────
  # Sysctl hardening (replaces base role)
  # ──────────────────────────────────────────────
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.default.accept_redirects" = 0;
  };

  # ──────────────────────────────────────────────
  # Fail2ban
  # ──────────────────────────────────────────────
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";

    jails = {
      sshd = {
        settings = {
          enabled = true;
          port = "ssh";
          maxretry = 3;
          bantime = "1h";
          findtime = "10m";
        };
      };
    };
  };

  # ──────────────────────────────────────────────
  # ACME / Let's Encrypt (replaces certbot)
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


  # ──────────────────────────────────────────────
  # Stalwart mail server
  # ──────────────────────────────────────────────
  services.stalwart-mail = {
    enable = true;
    settings = {
      server = {
        hostname = "stalwart.rubenhensen.nl";
        max-connections = 8192;
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
            bind = "127.0.0.1:8443";
            protocol = "http";
            tls.implicit = true;
          };
          http = {
            bind = "127.0.0.1:8080";
            protocol = "http";
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
        directory = "ldap";
      };

      store.rocksdb = {
        type = "rocksdb";
        path = "/var/lib/stalwart-mail/data";
        compression = "lz4";
      };

      directory.ldap = {
        type = "ldap";
        url = "ldap://127.0.0.1:3389";
        base-dn = "DC=ldap,DC=goauthentik,DC=io";
        bind.dn = "cn=ldapservice,ou=users,DC=ldap,DC=goauthentik,DC=io";
        bind.secret = "%{file:/run/secrets/stalwart-ldap-password}%";
        filter.name = "(&(objectClass=user)(cn=?))";
        filter.email = "(&(objectClass=user)(mail=?))";
        filter.verify = "(&(objectClass=user)(|(mail=*?*)(cn=*?*)))";
        filter.expand = "(&(objectClass=group)(cn=?))";
        attribute.name = "cn";
        attribute.email = "mail";
        attribute.description = "displayName";
      };

      tracer.stdout = {
        type = "stdout";
        level = "info";
        ansi = false;
        enable = true;
      };

      tracer.log = {
        type = "log";
        level = "info";
        path = "/var/lib/stalwart-mail/logs";
        prefix = "stalwart.log";
        rotate = "daily";
        ansi = false;
        enable = true;
      };

      authentication.fallback-admin = {
        user = "admin";
        secret = "%{file:/run/secrets/stalwart-admin-password}%";
      };
    };
  };

  # Grant stalwart and nginx access to ACME certs
  users.users.stalwart-mail.extraGroups = [ "acme" ];
  users.users.nginx.extraGroups = [ "stalwart-mail" ];

  # ──────────────────────────────────────────────
  # Nginx (reverse proxy + stream proxy to K8s)
  # ──────────────────────────────────────────────
  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = true;
    eventsConfig = "worker_connections 4096;";

    # HTTP upstream for K8s (included from mutable file)
    appendHttpConfig = ''
      include /run/nginx/k8s-http-upstream.conf;
    '';

    # Stream config for TLS SNI routing + LDAP proxy
    streamConfig = ''
      log_format stream '$remote_addr [$time_local] '
                        '$protocol $status $bytes_sent $bytes_received '
                        '$session_time "$ssl_preread_server_name"';
      access_log /var/log/nginx/stream.log stream;

      map $ssl_preread_server_name $tls_backend {
          stalwart.rubenhensen.nl  local_tls;
          default                  k8s_tls;
      }

      upstream local_tls {
          server 127.0.0.1:8443;
      }

      include /run/nginx/k8s-upstream.conf;

      server {
          listen 443;
          listen [::]:443;
          ssl_preread on;
          proxy_pass $tls_backend;
      }

      # LDAP proxy to K8s Authentik LDAP outpost
      server {
          listen 127.0.0.1:3389;
          proxy_pass k8s_ldap;
      }
    '';
  };

  # Create stream.d directory and initial upstream config
  systemd.tmpfiles.rules = [
    "d /run/secrets 0700 root root -"
    "d /var/lib/acme/acme-challenge 0755 acme acme -"
  ];

  # ──────────────────────────────────────────────
  # K8s IP update script (called via SSH)
  # ──────────────────────────────────────────────
  # Allow nginx to read/write mutable upstream configs
  systemd.services.nginx.serviceConfig.ReadWritePaths = [ "/run/nginx" ];
  systemd.services.nginx.serviceConfig.LimitNOFILE = 65536;
  systemd.services.nginx.preStart = lib.mkBefore ''
    mkdir -p /run/nginx
    test -f /run/nginx/k8s-upstream.conf || printf 'upstream k8s_tls {\n    server 127.0.0.1:443;\n}\n\nupstream k8s_ldap {\n    server 127.0.0.1:3389;\n}\n' > /run/nginx/k8s-upstream.conf
    test -f /run/nginx/k8s-http-upstream.conf || printf 'upstream k8s_http {\n    server 127.0.0.1:80;\n}\n' > /run/nginx/k8s-http-upstream.conf
  '';

  # Stalwart ACME HTTP-01 challenge
  services.nginx.virtualHosts."stalwart.rubenhensen.nl" = {
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

  # Catch-all port 80 — proxy to K8s for ACME challenges + redirect
  services.nginx.virtualHosts."_" = {
    default = true;
    listen = [
      { addr = "0.0.0.0"; port = 80; }
      { addr = "[::]"; port = 80; }
    ];
    locations."/" = {
      proxyPass = "http://k8s_http";
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      '';
    };
  };

  # IP update script (as a proper Nix package)
  environment.systemPackages = [ updateK8sIp pkgs.openssl ];

  # SSH authorized key for K8s IP updater (add the actual pubkey)
  users.users.root.openssh.authorizedKeys.keys = [
    # nix-infra will set the main SSH key via configuration.nix
    # Add the IP updater key with command restriction:
    ''command="${updateK8sIp}/bin/update-k8s-ip",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII5cMc73rlUCn3mS5FXlu3nO+AUeW2L28jRh22VYIPY4 k8s-ip-updater''
  ];

  # ──────────────────────────────────────────────
  # Automatic updates
  # ──────────────────────────────────────────────
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
  };
}
