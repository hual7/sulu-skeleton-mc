#!/bin/sh
# Back up the MariaDB database and media directories to a Bunny Storage
# rclone remote ("bunny:"). Safe to run from cron or the entrypoint — it
# never aborts the container: every failure is logged and the script still
# exits 0. Opt-in via BACKUP_ENABLED=true.
set -u

log() { echo "[backup $(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { log "ERROR: $*"; }

: "${BACKUP_ENABLED:=}"
if [ "$BACKUP_ENABLED" != "true" ]; then
    log "BACKUP_ENABLED is not 'true', skipping."
    exit 0
fi

# Serialize runs so a long media sync never overlaps the next cron tick or a
# concurrent pre-deploy run. Best-effort: probe writability in a subshell
# first, because a failed redirection on `exec` (a special builtin) would
# terminate the script outright — the backup must run even if the lock dir
# is missing or read-only.
LOCK=/var/lock/backup.lock
if command -v flock >/dev/null 2>&1 && ( : >>"$LOCK" ) 2>/dev/null; then
    exec 9>>"$LOCK"
    if ! flock -n 9; then
        log "another backup run is in progress, skipping."
        exit 0
    fi
fi

# The media paths below are relative to the app root; cron runs the job from
# a different cwd, so anchor here explicitly.
APP_ROOT="${APP_ROOT:-/var/www/html}"
cd "$APP_ROOT" || { fail "cannot enter app root '$APP_ROOT', aborting backup."; exit 0; }

: "${BACKUP_BUCKET:=}"
: "${BACKUP_RETENTION:=7}"
: "${BACKUP_KEEP_DELETED:=true}"
: "${APP_CACHE_DIR:=/var/cache/sulu}"
: "${DATABASE_URL:=}"
REMOTE="bunny:${BACKUP_BUCKET}"

db_dump() {
    # Parse DATABASE_URL: mysql://user:pass@host:port/dbname?params
    rest=${DATABASE_URL#*://}
    creds=${rest%%@*}
    hostpart=${rest#*@}
    user=${creds%%:*}
    pass=${creds#*:}
    [ "$pass" = "$creds" ] && pass=""
    hostportdb=${hostpart%%\?*}
    hostport=${hostportdb%%/*}
    db=${hostportdb#*/}
    host=${hostport%%:*}
    port=${hostport#*:}
    [ "$port" = "$hostport" ] && port=3306

    ts=$(date '+%Y%m%d-%H%M%S')
    tmpdir="$APP_CACHE_DIR/backup"
    mkdir -p "$tmpdir"
    raw="$tmpdir/sulu-$ts.sql"
    dump="$raw.gz"

    log "dumping database '$db' from $host:$port ..."
    # Dump to an uncompressed intermediate first: a shell pipeline reports
    # only the last command's status, so `mariadb-dump | gzip` would mask a
    # failed dump as success. Check mariadb-dump on its own.
    if MYSQL_PWD="$pass" mariadb-dump --single-transaction --quick --no-tablespaces \
        -h "$host" -P "$port" -u "$user" "$db" > "$raw"; then
        gzip -f "$raw"
        if rclone copy "$dump" "$REMOTE/db/"; then
            log "database dump uploaded: db/$(basename "$dump")"
        else
            fail "rclone copy of database dump failed."
        fi
    else
        fail "mariadb-dump failed."
    fi
    rm -f "$raw" "$dump"
}

db_retention() {
    files=$(rclone lsf "$REMOTE/db/" 2>/dev/null | grep '^sulu-.*\.sql\.gz$' | sort)
    total=$(printf '%s\n' "$files" | grep -c . || true)
    if [ "$total" -gt "$BACKUP_RETENTION" ]; then
        remove=$((total - BACKUP_RETENTION))
        printf '%s\n' "$files" | head -n "$remove" | while IFS= read -r f; do
            [ -n "$f" ] || continue
            log "pruning old dump: db/$f"
            rclone deletefile "$REMOTE/db/$f" || fail "could not prune db/$f"
        done
    fi
}

media_sync() {
    ts=$(date '+%Y%m%d-%H%M%S')
    for pair in "var/storage:storage" "public/uploads:uploads"; do
        src=${pair%%:*}
        dst=${pair#*:}
        [ -e "$src" ] || { log "skip $src (missing)"; continue; }
        set -- sync -L "$src" "$REMOTE/$dst"
        if [ "$BACKUP_KEEP_DELETED" = "true" ]; then
            set -- "$@" --backup-dir "$REMOTE/_deleted/$ts/$dst"
        fi
        log "syncing $src -> $dst ..."
        if rclone "$@"; then
            log "synced $dst."
        else
            fail "rclone sync of $src failed."
        fi
    done
}

db_dump
db_retention
media_sync
log "backup run complete."
exit 0
