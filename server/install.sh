#!/usr/bin/env bash
# Installs or updates the Wijkloper server as a systemd service.
#
#   Public HTTPS mode (VPS such as Lightsail):
#       sudo bash install.sh --domain wijkloper.example.org
#   Home-network mode (e.g. Raspberry Pi, plain http on port 8000):
#       sudo bash install.sh
#
# Public mode binds the API to localhost and puts Caddy in front of it. Caddy
# obtains and renews the Let's Encrypt certificate by itself; the domain must
# already point at this machine and TCP 80 + 443 must be open in the firewall.
#
# Idempotent: re-run it after copying a newer version of the server folder.
# The first install picks a random pairing code and PIN 1234; both can be
# changed in the app (Parent mode > Settings) or with `sudo wijkloper-cli`.
set -euo pipefail

DOMAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=/opt/wijkloper
DATA_DIR=/var/lib/wijkloper
ENV_FILE=/etc/wijkloper.env
SERVICE=wijkloper
SERVICE_USER=wijkloper
PORT="${WIJKLOPER_PORT:-8000}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo: sudo bash $0 ${DOMAIN:+--domain $DOMAIN}" >&2
  exit 1
fi

if [ -n "$DOMAIN" ]; then
  BIND=127.0.0.1
  UVICORN_ARGS="--proxy-headers --forwarded-allow-ips=127.0.0.1"
  PUBLIC_URL="https://$DOMAIN"
else
  BIND=0.0.0.0
  UVICORN_ARGS=""
  PUBLIC_URL="http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT"
fi

# --- Caddy (public mode only) ----------------------------------------------------

port_owner() {
  # Name of the process listening on TCP port $1, empty when the port is free.
  ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    return
  fi
  for p in 80 443; do
    owner="$(port_owner "$p")"
    if [ -n "$owner" ]; then
      echo "!! Port $p is already used by '$owner'. Stop it or configure it for $DOMAIN yourself," >&2
      echo "   then re-run without --domain and proxy https://$DOMAIN to 127.0.0.1:$PORT." >&2
      exit 1
    fi
  done
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "!! Automatic Caddy install needs Debian/Ubuntu. Install Caddy by hand first:" >&2
    echo "   https://caddyserver.com/docs/install" >&2
    exit 1
  fi
  echo "==> Installing Caddy (official apt repository)"
  apt-get update -qq
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy
}

configure_caddy() {
  local caddyfile=/etc/caddy/Caddyfile
  mkdir -p /etc/caddy
  if [ -f "$caddyfile" ] && grep -qE "^[[:space:]]*$DOMAIN([[:space:]]|,|\{|$)" "$caddyfile"; then
    echo "==> Caddyfile already has a site block for $DOMAIN; leaving it as is"
  else
    if [ -f "$caddyfile" ]; then
      local backup="$caddyfile.bak.$(date +%Y%m%d%H%M%S)"
      cp "$caddyfile" "$backup"
      echo "==> Adding $DOMAIN to the existing Caddyfile (backup: $backup)"
      # Neutralise the package's default ":80" catch-all block if it is still there.
      if grep -qE '^:80[[:space:]]*\{' "$caddyfile"; then
        sed -i -E 's/^:80[[:space:]]*\{/# (disabled by wijkloper install) :80 {/' "$caddyfile"
        sed -i -E '/^# \(disabled by wijkloper install\) :80 \{/,/^\}/ s/^([^#])/# \1/' "$caddyfile"
      fi
    else
      echo "==> Writing a new Caddyfile"
      : > "$caddyfile"
    fi
    cat >> "$caddyfile" <<EOF

# --- Wijkloper API (added by install.sh) ---
$DOMAIN {
    encode zstd gzip
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options "nosniff"
        -Server
    }
    reverse_proxy 127.0.0.1:$PORT
}
EOF
    if ! caddy validate --config "$caddyfile" --adapter caddyfile >/dev/null 2>&1; then
      echo "!! The resulting Caddyfile is invalid; restoring the previous one." >&2
      caddy validate --config "$caddyfile" --adapter caddyfile || true
      if [ -n "${backup:-}" ]; then cp "$backup" "$caddyfile"; fi
      exit 1
    fi
  fi
  systemctl enable --quiet caddy
  if systemctl is-active --quiet caddy; then
    systemctl reload caddy
  else
    systemctl start caddy
  fi
}

# --- Python service -------------------------------------------------------------

echo "==> Checking python3 + venv"
if ! python3 -c "import venv" 2>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq python3-venv
fi

echo "==> Creating service user and directories"
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
mkdir -p "$INSTALL_DIR" "$DATA_DIR"

echo "==> Copying application files to $INSTALL_DIR"
rm -rf "$INSTALL_DIR/app"
cp -r "$SRC_DIR/app" "$INSTALL_DIR/app"
find "$INSTALL_DIR/app" -name "__pycache__" -type d -prune -exec rm -rf {} +
cp "$SRC_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"

echo "==> Installing Python dependencies (this can take a few minutes the first time)"
if [ ! -x "$INSTALL_DIR/venv/bin/python" ]; then
  python3 -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip wheel
"$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"

if [ ! -f "$ENV_FILE" ]; then
  echo "==> Writing $ENV_FILE with a fresh pairing code"
  CODE="$(python3 -c 'import secrets; print(secrets.randbelow(90000000) + 10000000)')"
  cat > "$ENV_FILE" <<EOF
WIJKLOPER_DATA_DIR=$DATA_DIR
WIJKLOPER_PORT=$PORT
WIJKLOPER_PAIRING_CODE=$CODE
WIJKLOPER_PARENT_PIN=1234
WIJKLOPER_FAMILY_NAME=Our family
WIJKLOPER_ENABLE_DOCS=1
WIJKLOPER_TZ=Europe/Amsterdam
EOF
  chmod 600 "$ENV_FILE"
fi
# Mode-dependent lines are (re)written on every run so switching modes works.
sed -i '/^WIJKLOPER_BIND=/d;/^WIJKLOPER_UVICORN_ARGS=/d;/^WIJKLOPER_PUBLIC_URL=/d' "$ENV_FILE"
cat >> "$ENV_FILE" <<EOF
WIJKLOPER_BIND=$BIND
WIJKLOPER_UVICORN_ARGS=$UVICORN_ARGS
WIJKLOPER_PUBLIC_URL=$PUBLIC_URL
EOF

echo "==> Installing systemd service"
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=Wijkloper paper route API
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE_USER
Group=$SERVICE_USER
EnvironmentFile=$ENV_FILE
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python -m uvicorn app.main:app --host \${WIJKLOPER_BIND} --port \${WIJKLOPER_PORT} \$WIJKLOPER_UVICORN_ARGS
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

# Handy CLI wrapper: `sudo wijkloper-cli show`
cat > /usr/local/bin/wijkloper-cli <<EOF
#!/usr/bin/env bash
set -a; . $ENV_FILE; set +a
cd $INSTALL_DIR && exec sudo -E -u $SERVICE_USER $INSTALL_DIR/venv/bin/python -m app.cli "\$@"
EOF
chmod 755 /usr/local/bin/wijkloper-cli

chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
systemctl daemon-reload
systemctl enable --quiet "$SERVICE"
systemctl restart "$SERVICE"

sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  echo "!! Service failed to start. Last log lines:" >&2
  journalctl -u "$SERVICE" -n 30 --no-pager >&2
  exit 1
fi

if [ -n "$DOMAIN" ]; then
  install_caddy
  configure_caddy
  echo "==> Waiting for the certificate and checking https://$DOMAIN/api/health"
  ok=""
  for _ in $(seq 1 20); do
    if curl -fsS -m 10 "https://$DOMAIN/api/health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 3
  done
  if [ -z "$ok" ]; then
    echo "!! https://$DOMAIN does not answer yet. Check that DNS points here and that TCP 80/443 are open." >&2
    echo "   Caddy log: journalctl -u caddy -n 50 --no-pager" >&2
  fi
fi

echo
echo "================================================================"
echo " Wijkloper server is running."
echo " URL for the app:   $PUBLIC_URL"
if grep -q "WIJKLOPER_ENABLE_DOCS=1" "$ENV_FILE"; then
  echo " API docs:          $PUBLIC_URL/docs"
fi
echo
echo " Pairing code and PIN (from the database):"
/usr/local/bin/wijkloper-cli show | grep -E "Pairing code|Parent PIN" || true
echo
echo " Logs: journalctl -u $SERVICE -f${DOMAIN:+    (proxy: journalctl -u caddy -f)}"
echo "================================================================"
