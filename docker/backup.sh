#!/bin/sh
# Back up the MariaDB database and media directories to a Bunny Storage
# rclone remote ("bunny:"). Safe to run from cron or the entrypoint — it
# never aborts the container: every failure is logged and the script still
# exits 0. Opt-in via BACKUP_ENABLED=true.
set -u

log() { echo "[backup $(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { log "ERROR: $*"; }

# Serialize runs so a long media sync never overlaps the next cron tick or a
# concurrent pre-deploy run. Non-blocking: skip if another run holds the lock.
if command -v flock >/dev/null 2>&1; then
    exec 9>/var/lock/backup.lock
    if ! flock -n 9; then
        log "another backup run is in progress, skipping."
        exit 0
    fi
fi

: "${BACKUP_ENABLED:=}"
if [ "$BACKUP_ENABLED" != "true" ]; then
    log "BACKUP_ENABLED is not 'true', skipping."
    exit 0
fi

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
    dump="$tmpdir/sulu-$ts.sql.gz"

    log "dumping database '$db' from $host:$port ..."
    if MYSQL_PWD="$pass" mariadb-dump --single-transaction --quick --no-tablespaces \
        -h "$host" -P "$port" -u "$user" "$db" | gzip -c > "$dump"; then
        if rclone copy "$dump" "$REMOTE/db/"; then
            log "database dump uploaded: db/$(basename "$dump")"
        else
            fail "rclone copy of database dump failed."
        fi
    else
        fail "mariadb-dump failed."
    fi
    rm -f "$dump"
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
