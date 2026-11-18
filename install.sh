#!/usr/bin/env bash
# ProfitView browser edition installer – Chromium with ProfitView in a web desktop, behind HTTPS + password
#
#   curl -fsSL https://profitview.app/install.sh | bash -s -- '<ui-password>' [options]
#   install.sh update
#
# Run with --help for all options. Re-running changes password/domain/ports and keeps all ProfitView data.
set -euo pipefail

# CHECK(docker): final registry/org name, pin caddy tag [P2]
IMAGE="${PV_IMAGE:-ghcr.io/profitview/profitview-browser:latest}"
CADDY_IMAGE="caddy:2"
DIR=/opt/profitview
SELF=$(readlink -f "$0" 2>/dev/null || true)
EXT_ID=gmflieilmcgbdepadibceklnjbjimpof

PW="${PV_PASSWORD:-}"
DOMAIN=""
UI_USER=profitview
START_URL="https://www.tradingview.com/chart/"
HTTP_PORT=80
HTTPS_PORT=443
CERT=""
KEY=""
NO_PROXY=""
LOCAL=""
TAILSCALE=""
NO_PASSWORD=""
PROXY_PORT=3000
FIREWALL=1
DARK=""
TZONE=""
CMD=install

usage() {
	cat <<'EOF'
Usage: install.sh <ui-password> [options]
       install.sh update

  --domain HOST           own DNS name pointing to this server (default: <public-ip>.sslip.io)
  --user NAME             login name for the web UI (default: profitview)
  --start-url URL         second tab opened on start (default: https://www.tradingview.com/chart/)
  --http-port N           HTTP port (default 80)
  --https-port N          HTTPS port (default 443)
  --cert FILE --key FILE  use an existing certificate, e.g. /etc/letsencrypt/live/<name>/fullchain.pem + privkey.pem
  --no-proxy [PORT]       no built-in HTTPS proxy, web UI only on 127.0.0.1:PORT (default 3000)
                          for an existing web server (Apache/nginx/Caddy), a config snippet is printed
  --local [PORT]          no web proxy, web UI only on 127.0.0.1:PORT (default 3000), reach it via SSH tunnel
  --tailscale             like --local, plus Tailscale (installed if missing) serves it as
                          https://<server>.<tailnet>.ts.net (TS_AUTHKEY=... logs in unattended)
  --no-password           with --local/--tailscale only: no login prompt (SSH/Tailscale is the only protection)
  --no-firewall           don't change the firewall (ufw)
  --dark                  dark theme for the Chromium browser UI
  --tz ZONE               time zone, e.g. Europe/Berlin (default: server's)

The password (min. 12 characters) can also be passed via PV_PASSWORD or entered when prompted.

Ports: the built-in proxy needs port 80 or 443 reachable from the internet to get a free
Let's Encrypt certificate. If both are in use by another web server, either use --no-proxy
(recommended) or other ports together with --cert/--key (otherwise a self-signed certificate
is used and your browser shows a warning once). SSH is never touched, it stays the server's own.
EOF
}

die() { echo -e "\e[31mError: $*\e[0m" >&2; exit 1; }
warn() { echo -e "\e[33mWarning: $*\e[0m" >&2; }
info() { echo -e "\e[36m==> $*\e[0m"; }
need() { [ -n "${2:-}" ] || die "Option $1 needs a value"; }

while [ $# -gt 0 ]; do
	case "$1" in
		update) CMD=update ;;
		--domain) need "$1" "${2:-}"; DOMAIN="$2"; shift ;;
		--user) need "$1" "${2:-}"; UI_USER="$2"; shift ;;
		--start-url) need "$1" "${2:-}"; START_URL="$2"; shift ;;
		--http-port) need "$1" "${2:-}"; HTTP_PORT="$2"; shift ;;
		--https-port) need "$1" "${2:-}"; HTTPS_PORT="$2"; shift ;;
		--cert) need "$1" "${2:-}"; CERT="$2"; shift ;;
		--key) need "$1" "${2:-}"; KEY="$2"; shift ;;
		--no-proxy) NO_PROXY=1; if [[ "${2:-}" =~ ^[0-9]+$ ]]; then PROXY_PORT="$2"; shift; fi ;;
		--local) NO_PROXY=1; LOCAL=1; if [[ "${2:-}" =~ ^[0-9]+$ ]]; then PROXY_PORT="$2"; shift; fi ;;
		--tailscale) NO_PROXY=1; LOCAL=1; TAILSCALE=1 ;;
		--no-password) NO_PASSWORD=1 ;;
		--no-firewall) FIREWALL="" ;;
		--dark) DARK=1 ;;
		--tz) need "$1" "${2:-}"; TZONE="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) die "Unknown option: $1 (see --help)" ;;
		*) PW="$1" ;;
	esac
	shift
done

[ "$(id -u)" -eq 0 ] || die "Please run as root (e.g. with sudo)"

if [ "$CMD" = update ]; then
	[ -f "$DIR/docker-compose.yml" ] || die "No installation found in $DIR"
	info "Updating ProfitView..."
	docker compose -f "$DIR/docker-compose.yml" pull
	docker compose -f "$DIR/docker-compose.yml" up -d
	info "Done!"
	exit 0
fi

# --- preflight ---
. /etc/os-release 2>/dev/null || true
[[ "${ID:-}" =~ ^(debian|ubuntu)$ ]] || warn "Only tested on Debian/Ubuntu (found: ${ID:-unknown})"

if [ -n "$NO_PASSWORD" ]; then
	[ -n "$LOCAL" ] || die "--no-password only works together with --local or --tailscale"
	PW=""
	warn "No login prompt: anyone with SSH or tailnet access to this server can control the browser, including your exchange API keys"
else
	if [ -z "$PW" ]; then
		[ -e /dev/tty ] || die "No password given (pass it as first argument or via PV_PASSWORD)"
		read -rsp "Password for the web UI (min. 12 characters): " PW </dev/tty 2>/dev/null || die "No password given (pass it as first argument or via PV_PASSWORD)"
		echo
	fi
	[ ${#PW} -ge 12 ] || die "Password must have at least 12 characters"
fi
[[ "$START_URL" =~ ^https?://[^\"[:space:]]+$ ]] || die "Invalid --start-url: $START_URL"
[[ "$UI_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid --user: $UI_USER"
for p in "$HTTP_PORT" "$HTTPS_PORT" "$PROXY_PORT"; do [[ "$p" =~ ^[0-9]+$ ]] || die "Invalid port: $p"; done
if [ -n "$CERT$KEY" ]; then
	[ -n "$CERT" ] && [ -n "$KEY" ] || die "--cert and --key must be used together"
	[ -r "$CERT" ] && [ -r "$KEY" ] || die "Certificate or key file not readable"
fi

port_used() { ss -Htln "sport = :$1" 2>/dev/null | grep -q .; }
# a port is only free for us if nobody uses it or our own container already publishes it (re-run with the same port),
# otherwise the container would be recreated and then fail to start
ours() { command -v docker >/dev/null && docker port "$1" 2>/dev/null | grep -q ":$2\$"; }

if [ -n "$NO_PROXY" ]; then
	ours profitview "$PROXY_PORT" || ! port_used "$PROXY_PORT" || die "Port $PROXY_PORT is already in use, choose another one: --no-proxy <port>"
else
	for p in "$HTTP_PORT" "$HTTPS_PORT"; do
		if ! ours profitview-caddy "$p" && port_used "$p"; then die "Port $p is already in use (another web server?) – use --no-proxy, or --http-port/--https-port (see --help)"; fi
	done
fi

# --- packages ---
info "Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl openssl unattended-upgrades >/dev/null
if [ -n "$FIREWALL" ]; then apt-get install -y -qq ufw >/dev/null; fi
if ! command -v docker >/dev/null; then
	info "Installing Docker..."
	curl -fsSL https://get.docker.com | sh >/dev/null
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin missing (apt-get install docker-compose-plugin)"

# --- clock sync (the container uses the host's clock, signed exchange requests need it to be correct) ---
if [ "$(timedatectl show -p NTP --value 2>/dev/null)" != yes ]; then
	info "Enabling clock synchronization..."
	# only add timesyncd when no other sync service is installed, it would conflict with chrony/ntp
	command -v chronyd >/dev/null || command -v ntpd >/dev/null || apt-get install -y -qq systemd-timesyncd >/dev/null || true
	timedatectl set-ntp true 2>/dev/null || warn "Could not enable clock synchronization, please check the server's time sync (timedatectl)"
fi

# --- host name ---
IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me || true)
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { IP=""; [ -n "$NO_PROXY" ] || warn "Could not detect the public IPv4 address"; }
# the host name is only needed by the built-in proxy (Caddy), the IP otherwise only for the API key hint
if [ -z "$NO_PROXY" ]; then
	if [ -n "$DOMAIN" ]; then
		HOST="$DOMAIN"
		RESOLVED=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)
		[ -z "$IP" ] || [ "$RESOLVED" = "$IP" ] || warn "$DOMAIN resolves to '${RESOLVED:-nothing}', but this server is $IP"
	else
		[ -n "$IP" ] || die "Public IP unknown, please pass --domain"
		HOST="${IP//./-}.sslip.io"
	fi
	if [ -n "$CERT" ] && ! openssl x509 -in "$CERT" -noout -checkhost "$HOST" | grep -q "does match"; then
		warn "Certificate $CERT does not seem to be valid for $HOST"
	fi
fi
[ -n "$TZONE" ] || TZONE=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo Etc/UTC)

# --- files ---
info "Writing configuration to $DIR..."
mkdir -p "$DIR/config"
cd "$DIR"
umask 077

# bcrypt hash for Caddy and the htpasswd of --no-proxy (--local passes the password to the container instead)
HASH=""
if [ -z "$LOCAL" ]; then HASH=$(docker run --rm "$CADDY_IMAGE" caddy hash-password --plaintext "$PW"); fi
# container login (base image basic auth) for --local/--tailscale, as single-quoted YAML ("'" doubled)
# with "$" doubled for compose
AUTH_ENV=""
if [ -n "$LOCAL" ] && [ -n "$PW" ]; then
	PW_YAML=${PW//\$/\$\$}
	PW_YAML=${PW_YAML//\'/\'\'}
	AUTH_ENV="
      - CUSTOM_USER=$UI_USER
      - 'PASSWORD=$PW_YAML'"
fi

cat > policy.json <<EOF
{
  "RestoreOnStartup": 4,
  "RestoreOnStartupURLs": ["$START_URL"],
  "TabDiscardingExceptions": ["chrome-extension://$EXT_ID/*", "https://*.tradingview.com/*"],
  "ExtensionSettings": {
    "$EXT_ID": {"toolbar_pin": "force_pinned"}
  },
  "HighEfficiencyModeEnabled": false,
  "BackgroundModeEnabled": true,
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "TranslateEnabled": false,
  "MetricsReportingEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "PromotionalTabsEnabled": false,
  "DownloadDirectory": "/config/Downloads",
  "PromptForDownloadLocation": false
}
EOF
chmod 644 policy.json

CERT_MOUNT=""
if [ -n "$NO_PROXY" ]; then
	PROFITVIEW_PORTS="    ports:
      - \"127.0.0.1:$PROXY_PORT:3000\""
	CADDY_SERVICE=""
	rm -f Caddyfile htpasswd
	if [ -z "$LOCAL" ]; then
		# bcrypt $2y$ variant for Apache/nginx htpasswd
		echo "$UI_USER:${HASH/#\$2a\$/\$2y\$}" > htpasswd
		chmod 644 htpasswd
	fi
else
	PROFITVIEW_PORTS=""
	if [ -n "$CERT" ]; then
		TLS="	tls $CERT $KEY"
		# certbot live/ files are symlinks into archive/, so mount the whole tree
		if [[ "$CERT" == /etc/letsencrypt/* ]]; then CERT_MOUNT=/etc/letsencrypt; else CERT_MOUNT=$(dirname "$CERT"); fi
		[[ "$KEY" == "$CERT_MOUNT"/* ]] || die "--key must be in the same folder tree as --cert ($CERT_MOUNT)"
	elif [ "$HTTP_PORT" != 80 ] && [ "$HTTPS_PORT" != 443 ]; then
		TLS="	tls internal"
		warn "Neither port 80 nor 443 used – using a self-signed certificate (browser warning on first visit)"
	else
		TLS=""
	fi
	cat > Caddyfile <<EOF
{
	http_port $HTTP_PORT
	https_port $HTTPS_PORT
}

$HOST {
$TLS
	basic_auth {
		$UI_USER $HASH
	}
	reverse_proxy profitview:3000
}
EOF
	CADDY_SERVICE="  caddy:
    image: $CADDY_IMAGE
    container_name: profitview-caddy
    ports:
      - \"$HTTP_PORT:$HTTP_PORT\"
      - \"$HTTPS_PORT:$HTTPS_PORT\"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config${CERT_MOUNT:+
      - $CERT_MOUNT:$CERT_MOUNT:ro}
    restart: unless-stopped
"
	rm -f htpasswd
fi

cat > docker-compose.yml <<EOF
# generated by install.sh – re-run install.sh to change, "install.sh update" to update
name: profitview
services:
  profitview:
    image: $IMAGE
    container_name: profitview
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=$TZONE${DARK:+
      - CHROME_CLI=--force-dark-mode}$AUTH_ENV
    volumes:
      - ./config:/config
      - ./policy.json:/etc/chromium/policies/managed/profitview.json:ro
$PROFITVIEW_PORTS
    shm_size: 1gb
    restart: unless-stopped
$CADDY_SERVICE
volumes:
  caddy_data:
  caddy_config:
EOF
umask 022

# reload Caddy after certbot renewals (Caddy does not watch manually configured certificates)
if [ -n "$CERT" ] && [ -d /etc/letsencrypt/renewal-hooks/deploy ]; then
	cat > /etc/letsencrypt/renewal-hooks/deploy/profitview.sh <<EOF
#!/bin/sh
docker compose -f $DIR/docker-compose.yml exec -T caddy caddy reload --force --config /etc/caddy/Caddyfile
EOF
	chmod 755 /etc/letsencrypt/renewal-hooks/deploy/profitview.sh
fi

# --- firewall ---
if [ -n "$FIREWALL" ]; then
	info "Configuring firewall..."
	SSH_PORT=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)
	ufw allow "${SSH_PORT:-22}/tcp" >/dev/null
	if [ -z "$NO_PROXY" ]; then
		ufw allow "$HTTP_PORT/tcp" >/dev/null
		ufw allow "$HTTPS_PORT/tcp" >/dev/null
	fi
	ufw status | grep -q "Status: active" || ufw --force enable >/dev/null
fi

# --- Tailscale (--tailscale): HTTPS for the tailnet only, a plain http://<tailscale-ip> would not be a
# secure context, which the web desktop needs ---
TS_URL=""
if [ -n "$TAILSCALE" ]; then
	if ! command -v tailscale >/dev/null; then
		info "Installing Tailscale..."
		curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
	fi
	if ! tailscale status >/dev/null 2>&1; then
		if [ -n "${TS_AUTHKEY:-}" ]; then
			tailscale up --authkey "$TS_AUTHKEY"
		elif [ -e /dev/tty ]; then
			info "Log this server in to your tailnet with the link below..."
			tailscale up </dev/tty
		else
			die "This server is not logged in to Tailscale: run \"tailscale up\" (or pass TS_AUTHKEY=...), then re-run this command"
		fi
	fi
	tailscale serve --bg --https=443 "http://127.0.0.1:$PROXY_PORT" >/dev/null ||
		die "\"tailscale serve\" failed: enable MagicDNS and HTTPS Certificates in the Tailscale admin console (DNS page), then re-run this command"
	if [ -n "$FIREWALL" ]; then ufw allow in on tailscale0 to any port 443 proto tcp >/dev/null; fi
	TS_URL=$(tailscale serve status 2>/dev/null | grep -o 'https://[^ ]*' | head -1 || true)
	touch "$DIR/tailscale"
elif [ -f "$DIR/tailscale" ]; then
	# switched away from --tailscale: stop serving the old address
	tailscale serve --https=443 off >/dev/null 2>&1 || true
	rm -f "$DIR/tailscale"
fi

# --- start ---
info "Starting ProfitView (first start downloads ~1-2 GB)..."
docker compose pull -q
docker compose up -d --remove-orphans

if [ -n "$NO_PROXY" ]; then
	CHECK_URL="http://127.0.0.1:$PROXY_PORT/"
	OK_CODE=$([ -n "$AUTH_ENV" ] && echo 401 || echo 200)
else
	URL="https://$HOST$([ "$HTTPS_PORT" = 443 ] || echo ":$HTTPS_PORT")"
	CHECK_URL="$URL/"
	OK_CODE=401
fi
info "Waiting for $CHECK_URL ..."
for i in $(seq 1 36); do
	code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "$CHECK_URL" || true)
	[ "$code" = "$OK_CODE" ] && break
	sleep 5
done
[ "$code" = "$OK_CODE" ] || warn "Not reachable yet (last response: $code) – check with: docker compose -f $DIR/docker-compose.yml logs"

# --- summary ---
echo
info "ProfitView is installed!"
if [ -n "$LOCAL" ]; then
	LOGIN=$([ -n "$PW" ] && echo "user \"$UI_USER\", the password you entered" || echo "no login (--no-password)")
	echo
	if [ -n "$TAILSCALE" ]; then
		cat <<EOF
  Open:        ${TS_URL:-https://<server>.<tailnet>.ts.net (see: tailscale serve status)}
               from any device in your tailnet ($LOGIN)
  Fallback:    SSH tunnel, see below
EOF
	fi
	cat <<EOF
  SSH tunnel:  ssh -N -L 3000:127.0.0.1:$PROXY_PORT <you>@${IP:-<server>}
  Then open:   http://localhost:3000 ($LOGIN)
EOF
elif [ -n "$NO_PROXY" ]; then
	cat <<EOF

The web UI only listens on 127.0.0.1:$PROXY_PORT – add it to your existing web server
(password file for the user "$UI_USER": $DIR/htpasswd). Websockets must be proxied as well.

--- Apache 2.4.47+ (a2enmod proxy proxy_http proxy_wstunnel) ---
<VirtualHost *:443>
    ServerName pv.yourdomain.com
    # ... your existing SSLEngine / SSLCertificateFile / SSLCertificateKeyFile lines ...
    <Location />
        AuthType Basic
        AuthName "ProfitView"
        AuthUserFile $DIR/htpasswd
        Require valid-user
    </Location>
    ProxyPass / http://127.0.0.1:$PROXY_PORT/ upgrade=websocket
    ProxyPassReverse / http://127.0.0.1:$PROXY_PORT/
</VirtualHost>

--- nginx ---
server {
    listen 443 ssl;
    server_name pv.yourdomain.com;
    # ... your ssl_certificate lines ...
    auth_basic "ProfitView";
    auth_basic_user_file $DIR/htpasswd;
    location / {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1d;
    }
}

--- Caddy ---
pv.yourdomain.com {
    basic_auth {
        $UI_USER $HASH
    }
    reverse_proxy 127.0.0.1:$PROXY_PORT
}
EOF
else
	cat <<EOF

  Open:      $URL
  User:      $UI_USER
  Password:  (the one you entered)
EOF
fi
cat <<EOF

Next steps:
  1. In the ProfitView tab: "Paste Conf" at the top right (or set up from scratch), then log in
     under "Setup: Unlock PRO" with your email address + license code.
  2. In the second tab: log in to TradingView once.
  3. Exchange API keys: disable withdrawals and restrict them to this server's IP${IP:+ ($IP)}!

Update later with:  bash $DIR/install.sh update   (or re-run the curl command with "update")
EOF
# keep a local copy for "install.sh update" (when piped from curl there is no script file to copy)
# CHECK(docker): final download URL [P3]
if [ -f "$SELF" ]; then [ "$SELF" = "$DIR/install.sh" ] || cp -f "$SELF" "$DIR/install.sh"; else curl -fsSL https://profitview.app/install.sh -o "$DIR/install.sh" || true; fi
