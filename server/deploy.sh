#!/usr/bin/env bash
#
# Push the project to the match server and restart it.
#
#   server/deploy.sh root@203.0.113.10            # upload + restart
#   server/deploy.sh root@203.0.113.10 --dry-run  # show what would be sent
#
# Run it from the RemiShowdown directory (or anywhere - it locates itself).
# Works from Git Bash on Windows; it only needs ssh and rsync, or falls back to
# scp+tar if rsync is not present.
#
# WHAT GETS SENT, AND WHY SO LITTLE
# The server never loads a scene, a texture or a font: fd_server.gd runs the
# rules engine and a socket. So this sends the scripts and project.godot and
# nothing else - about 3 MB instead of the ~600 MB the project weighs on disk.
#
#   android/   207 MB of Android build templates. Never used server-side.
#   .godot/    the import cache. Not sent, EXCEPT global_script_class_cache.cfg,
#              which is uploaded separately below. It holds only res:// paths,
#              nothing host-specific, and regenerating it server-side does not
#              work - see the note above that upload.
#   Asset/     art. Sent anyway (1.8 MB) because a headless editor pass imports
#              whatever the .tscn files reference, and a missing texture turns
#              that pass into a wall of errors.
set -euo pipefail

TARGET="${1:-}"
DRY="${2:-}"
if [[ -z "$TARGET" ]]; then
	echo "usage: $0 user@host [--dry-run]" >&2
	exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE=/opt/remi/game

EXCLUDES=(
	--exclude ".godot/"
	--exclude "android/"
	--exclude ".git/"
	--exclude "*.apk"
	--exclude "*.tmp"
	--exclude "export_presets.cfg"   # holds local keystore paths
)

echo "deploying $HERE -> $TARGET:$REMOTE"

if command -v rsync >/dev/null 2>&1; then
	RSYNC_ARGS=(-az --delete "${EXCLUDES[@]}")
	[[ "$DRY" == "--dry-run" ]] && RSYNC_ARGS+=(--dry-run --itemize-changes)
	rsync "${RSYNC_ARGS[@]}" "$HERE/" "$TARGET:$REMOTE/"
else
	echo "rsync not found, falling back to tar over ssh"
	if [[ "$DRY" == "--dry-run" ]]; then
		echo "(dry run: would send $(du -sh --exclude=.godot --exclude=android "$HERE" | cut -f1))"
		exit 0
	fi
	# Keep this list in step with EXCLUDES above - they drifted once, and the tar
	# path shipped export_presets.cfg (which holds local keystore paths) while
	# the rsync path did not.
	tar -czf - -C "$HERE" \
		--exclude=.godot --exclude=android --exclude=.git \
		--exclude='*.apk' --exclude='*.tmp' --exclude=export_presets.cfg \
		. | ssh "$TARGET" "mkdir -p $REMOTE && tar -xzf - -C $REMOTE"
fi

[[ "$DRY" == "--dry-run" ]] && exit 0

# The script-class cache ships WITH the project rather than being regenerated
# on the server. It is 3 KB of res:// paths with nothing host-specific in it,
# and the alternative - a headless editor pass - quits before its filesystem
# scan finishes and silently produces no cache at all.
CACHE=".godot/global_script_class_cache.cfg"
if [[ ! -f "$HERE/$CACHE" ]]; then
	echo "ERROR: $CACHE not found locally." >&2
	echo "Open the project in the Godot editor once to generate it." >&2
	exit 1
fi
echo "uploading the script-class cache..."
scp -q "$HERE/$CACHE" "$TARGET:/tmp/global_script_class_cache.cfg"

echo "restarting..."
ssh "$TARGET" "
	mkdir -p $REMOTE/.godot
	cp /tmp/global_script_class_cache.cfg $REMOTE/.godot/
	chown -R remi:remi /opt/remi
	/usr/local/bin/remi-reload
"

echo
echo "done. Check it is listening:"
echo "  ssh $TARGET journalctl -u remi-server -n 20 --no-pager"
