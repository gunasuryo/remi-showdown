#!/usr/bin/env bash
#
# One-shot setup for an EXISTING Ubuntu/Debian server.
#
#   scp server/setup.sh root@<ip>:/root/
#   ssh root@<ip> "bash /root/setup.sh remishowdown.duckdns.org"
#
# Same end state as server/cloud-init.yaml. Use this one when the server is
# already running: cloud-init only executes on a machine's FIRST boot, so
# pasting a cloud-config into an existing VPS does nothing at all.
#
# Pass no domain to skip Caddy and serve plain ws:// on 8910 instead. That only
# works from Android if the APK was built with cleartext allowed - see
# server/HOSTING.md.
#
# Safe to run more than once.
set -euo pipefail

DOMAIN="${1:-}"
GODOT_VERSION="4.1.3-stable"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
PORT=8910

say() { printf "\n\033[1;36m== %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m!! %s\033[0m\n" "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || {
	echo "This installs the x86_64 Godot build but the machine is $(uname -m)." >&2
	echo "On an ARM instance (Hetzner CAX), change GODOT_URL to the linux.arm64 archive." >&2
	exit 1
}

say "installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# Godot's Linux build links X11/GL/ALSA even under --headless; without them it
# fails to start with a confusing loader error rather than anything useful.
apt-get install -y -qq unzip curl ca-certificates ufw \
	libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libxext6 libgl1 libpulse0 \
	libfontconfig1 libfreetype6
# ALSA's package was renamed in Ubuntu 24.04 (t64 ABI transition).
apt-get install -y -qq libasound2t64 || apt-get install -y -qq libasound2 || true

say "installing Godot ${GODOT_VERSION}"
if [[ ! -x /opt/godot/godot ]]; then
	mkdir -p /opt/godot
	curl -fsSL -o /tmp/godot.zip "$GODOT_URL"
	unzip -o -q /tmp/godot.zip -d /opt/godot
	mv /opt/godot/Godot_v${GODOT_VERSION}_linux.x86_64 /opt/godot/godot
	chmod +x /opt/godot/godot
	rm -f /tmp/godot.zip
fi
/opt/godot/godot --headless --version || { echo "Godot will not run" >&2; exit 1; }

say "creating the remi service user"
id -u remi >/dev/null 2>&1 || useradd --system --home-dir /opt/remi --shell /usr/sbin/nologin remi
mkdir -p /opt/remi/game
chown -R remi:remi /opt/remi

say "writing the systemd unit"
cat > /etc/systemd/system/remi-server.service <<UNIT
[Unit]
Description=Remi Showdown face-down match server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=remi
Group=remi
WorkingDirectory=/opt/remi/game
Environment=HOME=/opt/remi
Environment=XDG_DATA_HOME=/opt/remi/.local/share
Environment=XDG_CONFIG_HOME=/opt/remi/.config
ExecStart=/opt/godot/godot --headless --path /opt/remi/game --script res://server/fd_server.gd -- port=${PORT}
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/remi

[Install]
WantedBy=multi-user.target
UNIT

say "writing remi-reload"
cat > /usr/local/bin/remi-reload <<'RELOAD'
#!/usr/bin/env bash
# Restart the match server, refusing to do so if the script-class cache is
# missing.
#
# The cache (.godot/global_script_class_cache.cfg) is what lets the server
# resolve FDRules, FDNet and friends by class_name. It is UPLOADED by
# deploy.sh, not generated here: `--editor --quit` quits on the first frame
# while the filesystem scan is still running on another thread, which aborts
# the scan, writes no cache, and still exits 0. That looked like success and
# left the service crash-looping on "Identifier FDNet not declared".
set -euo pipefail
CACHE=/opt/remi/game/.godot/global_script_class_cache.cfg
if [[ ! -f "$CACHE" ]]; then
	echo "ERROR: $CACHE is missing." >&2
	echo "The server cannot resolve class_name types without it. Upload it:" >&2
	echo "  scp .godot/global_script_class_cache.cfg root@<host>:/tmp/" >&2
	echo "  ssh root@<host> 'mkdir -p /opt/remi/game/.godot && cp /tmp/global_script_class_cache.cfg /opt/remi/game/.godot/ && chown -R remi:remi /opt/remi'" >&2
	exit 1
fi
systemctl restart remi-server
sleep 2
systemctl --no-pager --lines=15 status remi-server
RELOAD
chmod +x /usr/local/bin/remi-reload

say "firewall"
ufw allow 22/tcp >/dev/null
if [[ -n "$DOMAIN" ]]; then
	ufw allow 80/tcp >/dev/null
	ufw allow 443/tcp >/dev/null
else
	warn "no domain given - opening ${PORT} for plain ws://, which Android blocks by default"
	ufw allow ${PORT}/tcp >/dev/null
fi
ufw --force enable >/dev/null
ufw status

if [[ -n "$DOMAIN" ]]; then
	say "installing Caddy for TLS on ${DOMAIN}"
	if ! command -v caddy >/dev/null 2>&1; then
		# Official apt repo; falls back to the release binary if it is unreachable.
		if curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
			| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null \
			&& curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
				> /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null; then
			apt-get update -qq && apt-get install -y -qq caddy
		else
			warn "apt repo unavailable, fetching the Caddy binary directly"
			curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /usr/local/bin/caddy
			chmod +x /usr/local/bin/caddy
			useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null || true
			mkdir -p /var/lib/caddy && chown caddy:caddy /var/lib/caddy
			cat > /etc/systemd/system/caddy.service <<'CADDY'
[Unit]
Description=Caddy
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-abnormal
AmbientCapabilities=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
CADDY
		fi
	fi

	mkdir -p /etc/caddy
	cat > /etc/caddy/Caddyfile <<CADDYFILE
${DOMAIN} {
	reverse_proxy 127.0.0.1:${PORT}
}
CADDYFILE
	systemctl daemon-reload
	systemctl enable --now caddy
	systemctl reload caddy 2>/dev/null || systemctl restart caddy
fi

say "enabling the game service"
systemctl daemon-reload
systemctl enable remi-server >/dev/null

echo
echo "-------------------------------------------------------------"
echo "Server prepared. /opt/remi/game is still EMPTY."
echo
# Resolve the address HERE, on the server, and print a literal command. The
# earlier version embedded $(curl ifconfig.me) in the printed text, which then
# ran on whatever machine the user pasted it into - returning their home IP.
DEPLOY_HOST="${DOMAIN:-$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || echo '<this-ip>')}"
echo "Next, from your machine (in the RemiShowdown directory):"
echo "    server/deploy.sh root@${DEPLOY_HOST}"
echo
if [[ -n "$DOMAIN" ]]; then
	echo "Lobby address:  wss://${DOMAIN}"
	echo "Certificate:    journalctl -u caddy -n 20 --no-pager"
else
	echo "Lobby address:  ws://<this-ip>:${PORT}   (Android needs a cleartext build)"
fi
echo "-------------------------------------------------------------"
