# Hosting the match server

**Status: the server is expected to be DELETED.** Online play will not work
until one is rebuilt. Single-player against the AI is unaffected — it needs no
server at all.

This file is written for whoever rebuilds it, including a fresh Claude session
with no memory of the original build. It is deliberately specific about the
things that went wrong the first time, because most of them fail *silently*.

---

## What the server is

`server/fd_server.gd` — one file, no database, no accounts. A room is a
four-letter code held in memory; restart the process and matches are gone. That
is the right trade for a game played with friends.

It runs under **headless Godot, the same engine and the same `FDRules` the
client runs**. There is no second implementation of the rules to drift.

It is *authoritative*: it owns the only real `FDState` and sends each client a
redacted copy that physically does not contain the opponent's hidden row. Every
move is re-validated with `FDRules.resolve()`. See `Scene/FaceDown/fd_net.gd`.

---

## Facts you need

| thing | value |
|---|---|
| Godot version | `4.1.3-stable`, Linux **x86_64** build |
| Game port | `8910` (loopback only when Caddy is in front) |
| Public port | `443` via Caddy → `wss://` |
| Install path | `/opt/remi/game`, service user `remi` |
| Service | `remi-server.service` |
| Restart helper | `remi-reload` (on the server) |
| Protocol version | `1` (`FDNet.PROTOCOL_VERSION`) |
| Seat hold after a drop | 180 s (`fd_server.gd`) |
| Client default address | `GameState.DEFAULT_SERVER_URL` |

The last one matters: the client ships with a server baked in, so **rebuilding
the server on a new address means editing `Scene/GameState.gd` and re-exporting
both clients.**

---

## Rebuild, start to finish

### 1. Create the VPS

Any provider. The original was **Hetzner CX22, Ubuntu 24.04, x86**.

> `setup.sh` downloads the **x86_64** Godot build and refuses to run on ARM. On
> a Hetzner CAX (ARM) instance, change `GODOT_URL` in `setup.sh` to the
> `linux.arm64` archive first.

Add your SSH key during creation. `cloud-init.yaml` exists in this directory but
**cloud-init only runs on a machine's FIRST boot** — pasting it into an already
running VPS does nothing, which is how the first attempt was lost. Either paste
it as user-data at creation time, or skip it and use `setup.sh` below.

### 2. Point a DNS name at it

Android **blocks cleartext `ws://`**, so a plain IP will not work from a phone.
You need a hostname for a certificate. Free and adequate: **duckdns.org** —
sign in, pick a name, paste the VPS IPv4 into the *current ip* field.

> DuckDNS pre-fills that box with the IP of whoever is *viewing the page* — your
> home connection. It must be overwritten with the server's address. This cost
> an hour the first time; `nslookup <name>.duckdns.org` must return the VPS IP
> before continuing.

### 3. Prepare the server

```bash
scp server/setup.sh root@<ip>:/root/
ssh root@<ip> "bash /root/setup.sh <name>.duckdns.org"
```

Note `bash setup.sh …` — Linux does not look in the current directory for
commands, so bare `setup.sh` gives "command not found".

Idempotent; safe to re-run. It installs Godot and Caddy, creates the `remi`
user, writes the systemd unit and `remi-reload`, and opens 22/80/443.

Pass **no** domain and it skips Caddy and serves plain `ws://` on 8910 — usable
from a PC, never from Android.

### 4. Upload the game

```bash
server/deploy.sh root@<name>.duckdns.org
```

~3 MB. Uses `rsync`, falling back to tar-over-ssh (Git Bash has no rsync).

### 5. Point the client at it and re-export

Edit `Scene/GameState.gd`:

```gdscript
const DEFAULT_SERVER_URL := "wss://<name>.duckdns.org"
```

Then re-export **both** clients — the address is compiled in:

```bash
godot --headless --path . --export-debug "Android" out/RemiShowdown.apk
godot --headless --path . --export-debug "Windows Desktop" out/RemiShowdown.exe
```

Android export needs `JAVA_HOME` set (Android Studio's bundled JDK works:
`C:\Program Files\Android\Android Studio\jbr`). Without it, every `apksigner`
fails and the APK comes out unsigned and uninstallable.

> Players who already ran the old build have the old address saved in
> `user://remi.cfg`, which **overrides the new default**. They can fix it via
> *change* in the lobby, or clear app data.

### 6. Verify

```bash
ssh root@<host> "journalctl -u remi-server -n 20 --no-pager"   # listening on 8910
ssh root@<host> "journalctl -u caddy -n 20 --no-pager"         # certificate obtained
```

Then the real check — a full match between two clients, from your machine:

```bash
godot --headless --path . --script res://test/test_fd_server.gd -- url=wss://<name>.duckdns.org
```

Both clients are driven by the AI, which can only see `FDState.observe()`. If it
can play a legal match from a redacted snapshot, the snapshot carries what a
player needs and nothing more.

---

## Traps, all of which cost real time

**The script-class cache must be UPLOADED, not regenerated.**
`fd_server.gd` resolves `FDRules`, `FDNet` and friends by `class_name`, and that
table lives in `.godot/global_script_class_cache.cfg`. Generating it on the
server with `--editor --quit` does not work: `--quit` exits on the first frame
while the filesystem scan is still running on another thread, so the scan aborts,
no cache is written, **and it still exits 0**. The service then crash-loops on
`Identifier "FDNet" not declared in the current scope`. `deploy.sh` uploads the
file (3 KB, only `res://` paths) and `remi-reload` refuses to restart without it.

**A GDScript parse error takes the whole class down silently.**
The server will not start and the only symptom is a connection that never
completes. Always check `journalctl -u remi-server` after a deploy.

**Godot needs X11/GL/font libraries even headless.**
`setup.sh` installs them. A missing `libfontconfig1` shows up as a loader
message, not a clean error.

**`usesCleartextTraffic` is not available in Godot's Android export.**
Verified absent in both 4.1.3 and 4.5 — the export plugin patches `allowBackup`,
`isGame`, `requestLegacyExternalStorage` and `screenOrientation`, and nothing
else. Allowing `ws://` on Android requires a Gradle custom build with a
hand-edited manifest. That was tried, the Gradle build failed, and it is not
worth it — **use `wss://`**.

**The Android INTERNET permission must be on.**
`permissions/internet=true` in `export_presets.cfg`. Without it the phone sits on
"Connecting…" forever while the PC build works fine, because desktop has no such
permission. `export_presets.cfg` is **gitignored** (it holds local keystore
paths), so a fresh clone will not have it — check this setting after any
re-clone.

---

## Costs and teardown

A CX22 is roughly €4/month. There is nothing to back up: no database, no state
worth keeping, and matches do not survive a restart anyway. Deleting the server
loses nothing but the address.

To shut down: delete the VPS, and optionally free the DuckDNS name. Leave
`DEFAULT_SERVER_URL` pointing at the dead host or set it to `""` — either way
online play will fail to connect and single-player is unaffected.
