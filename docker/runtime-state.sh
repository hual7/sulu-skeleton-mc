#!/bin/sh
# Durable runtime state on Bunny Storage (the rclone "bunny:" remote), under a
# _runtime/ prefix — separate from the _backup/ prefix that backup.sh uses.
# Unlike the node-bound MC volumes, this store survives a total volume loss, so
# it is the authoritative record of redeploy-relevant facts such as "has the app
# ever been initialised?".
#
# Meant to be SOURCED (not executed) by entrypoint.sh. Every function degrades to
# "not configured / unknown" when the Bunny credentials are absent, so the caller
# can fall back to local state instead of blocking startup.

: "${BACKUP_BUCKET:=}"
RUNTIME_REMOTE="bunny:${BACKUP_BUCKET}/_runtime"

# Bounded rclone call: a slow or unreachable remote must not stall container
# start — keep the ceiling low so we fall back to local state quickly.
runtime_rc() {
    rclone --contimeout 15s --timeout 30s --retries 1 --low-level-retries 2 "$@"
}

# True when the Bunny remote has enough config to be usable at all.
runtime_configured() {
    [ -n "$BACKUP_BUCKET" ] && [ -n "${RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID:-}" ]
}

# 0 = remote reachable (bucket root lists), 1 = unconfigured or unreachable.
runtime_reachable() {
    runtime_configured || return 1
    runtime_rc lsf --max-depth 1 "bunny:${BACKUP_BUCKET}/" >/dev/null 2>&1
}

# 0 = object <name> exists under _runtime/, 1 = absent. Only meaningful after
# runtime_reachable has succeeded.
runtime_exists() {
    runtime_rc lsf "$RUNTIME_REMOTE/" 2>/dev/null | grep -qx "$1"
}

# Write object <name> to _runtime/. With a second arg, uploads that file;
# otherwise writes an empty marker object. Returns rclone's exit status.
runtime_put() {
    name="$1"; src="${2:-}"; tmp=""
    runtime_configured || return 1
    if [ -z "$src" ]; then
        src=$(mktemp) || return 1
        tmp="$src"
    fi
    runtime_rc copyto "$src" "$RUNTIME_REMOTE/$name"
    rv=$?
    [ -n "$tmp" ] && rm -f "$tmp"
    return $rv
}
