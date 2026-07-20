#!/bin/sh
set -e

cd /var/www/html

: "${SULU_ADMIN_USER:=admin}"
: "${SULU_ADMIN_PASSWORD:=admin}"
: "${SULU_ADMIN_EMAIL:=admin@example.com}"

: "${APP_CACHE_DIR:=/var/cache/sulu}"
export APP_CACHE_DIR

# Some volume backends (e.g. Magic Containers) force file ownership to
# root and silently ignore chown, so www-data can only write where the
# permission bits allow it. Make everything group/world-writable and
# keep it that way for files created later by console commands and
# Apache. Acceptable tradeoff inside a single-app container.
umask 000

# Older images symlinked all of var/ into APP_DATA_DIR — undo that.
# Only var/storage, var/indexes and public/uploads live on the volume
# now; data already in those subdirectories is picked up as-is.
if [ -L var ]; then
    rm var
    mkdir var
fi

# Three directories hold data that must survive deploys: media
# originals (var/storage, flysystem), the Loupe search index
# (var/indexes) and generated image formats (public/uploads).
# Everything else under var/ is rebuilt at runtime — the Symfony cache
# lives in APP_CACHE_DIR outside the volume. Remove stale cache an
# older image may have left behind; leftover root-owned files there
# would break cache:clear.
rm -rf var/cache

# Persistent-volume mode: mount the app volume at /data and set
# APP_DATA_DIR=/data — var/storage, var/indexes and public/uploads
# become symlinks into it. With a single volume shared between app and
# db, point APP_DATA_DIR at a subdirectory (e.g. /data/app) instead so
# the containers stay out of each other's way (see README). When a
# volume is mounted directly at var/, leave APP_DATA_DIR unset.
if [ -n "${APP_DATA_DIR:-}" ]; then
    if mountpoint -q var; then
        echo "WARNING: APP_DATA_DIR is set but a volume is mounted at var/ — ignoring APP_DATA_DIR." >&2
    else
        for dir in storage indexes uploads; do
            case $dir in
                uploads) link=public/uploads ;;
                *) link=var/$dir ;;
            esac
            mkdir -p "$APP_DATA_DIR/$dir"
            if [ ! -L "$link" ]; then
                rm -rf "$link"
                ln -s "$APP_DATA_DIR/$dir" "$link"
            fi
        done
        chmod -R a+rwX "$APP_DATA_DIR"
    fi
fi

# var/ (or a freshly mounted, empty volume) may lack the layout —
# recreate it and make it writable for www-data before running any
# console command. chown covers volume backends with working
# ownership; chmod covers the ones that force ownership to root (see
# umask note above). chmod -R does not descend into the APP_DATA_DIR
# symlinks — the block above already covered their targets.
mkdir -p "$APP_CACHE_DIR" var/log var/share var/indexes var/sessions var/storage public/uploads public/bundles
chown www-data:www-data "$APP_CACHE_DIR" var var/log var/share var/indexes var/sessions var/storage public/uploads public/bundles || true
chmod -R a+rwX "$APP_CACHE_DIR" var public/uploads public/bundles

console() {
    gosu www-data php "$@"
}

# Wait for the database to accept connections. Magic Containers starts the
# app and db containers together with no ordering guarantee, so the app polls
# instead of relying on start order. One attempt per second; tune the ceiling
# via DB_WAIT_RETRIES for slow cold starts (e.g. first-ever volume init).
: "${DB_WAIT_RETRIES:=120}"
echo "Waiting for database (up to ${DB_WAIT_RETRIES}s)..."
i=0
until console bin/adminconsole doctrine:query:sql "SELECT 1" > /dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge "$DB_WAIT_RETRIES" ]; then
        echo "ERROR: database was not reachable after ${DB_WAIT_RETRIES} seconds, giving up." >&2
        exit 1
    fi
    sleep 1
done
echo "Database is ready."

# sulu:build must run exactly ONCE, on the very first deploy — it builds the
# Sulu schema and initial content into an empty database. "Is the DB empty?"
# alone is an unsafe trigger: MC volumes are node-bound and can come back
# blank (see README / persistent-volume notes), and an empty DB would then
# silently rebuild a fresh, blank site over the loss. Two markers record that
# the first build already happened:
#   - a local marker on the DATA volume (fast, no network)
#   - _runtime/.initialized on Bunny Storage (survives total volume loss and is
#     therefore AUTHORITATIVE whenever the remote is reachable)
# so a later empty DB is treated as data loss (refuse to start) instead of a
# first deploy. Deliberate rebuilds: set SULU_FORCE_BUILD=true.
. /usr/local/lib/runtime-state.sh

DATA_ROOT="${APP_DATA_DIR:-var}"
LOCAL_MARKER="$DATA_ROOT/.sulu-initialized"

db_built() {
    # Succeeds once the Sulu schema exists (se_users table present), even with
    # zero rows; fails on a truly empty database.
    console bin/adminconsole doctrine:query:sql "SELECT 1 FROM se_users LIMIT 1" > /dev/null 2>&1
}

# Prior-initialisation from the most durable evidence available:
#   yes | no | unknown  (no = remote reachable AND marker definitively absent)
if runtime_reachable; then
    if runtime_exists ".initialized"; then initialized=yes; else initialized=no; fi
    echo "Init state (Bunny Storage _runtime): initialized=$initialized"
elif [ -f "$LOCAL_MARKER" ]; then
    initialized=yes
    echo "Init state (local marker; remote unavailable): initialized=yes"
else
    initialized=unknown
    echo "Init state: no durable and no local marker."
fi

fresh_db=0
if db_built; then
    :  # DB intact — nothing to build; markers are (back)filled below.
elif [ "$initialized" = "yes" ] && [ "${SULU_FORCE_BUILD:-}" != "true" ]; then
    echo "ERROR: the app was initialised before (durable marker present) but the" >&2
    echo "       database is empty — it has been lost. Refusing to build a blank" >&2
    echo "       site over it. Restore the database from a backup, or set" >&2
    echo "       SULU_FORCE_BUILD=true to force a fresh build." >&2
    exit 1
else
    # Genuine first deploy (no durable evidence of a prior init), or forced.
    echo "Empty database detected, running sulu:build prod..."
    console bin/adminconsole sulu:build prod --no-interaction
    fresh_db=1
fi

# Persist / backfill both markers now that the DB is known-good. The local
# marker self-heals a reset data volume; the durable one closes the "both
# volumes lost" gap and backfills for deployments adopting this logic.
mkdir -p "$DATA_ROOT" 2>/dev/null || true
: > "$LOCAL_MARKER" 2>/dev/null || true
if runtime_configured && ! runtime_exists ".initialized"; then
    if runtime_put ".initialized"; then
        echo "Wrote durable init marker: ${RUNTIME_REMOTE}/.initialized"
    else
        echo "WARNING: could not write durable init marker to Bunny Storage." >&2
    fi
fi

# sulu:build prod does not create any user (only the dev target does).
# role:create grants full permissions (127) on all security contexts;
# it exits non-zero if the role already exists, e.g. after an aborted
# first start, hence the || true.
if ! console bin/adminconsole doctrine:query:sql "SELECT username FROM se_users WHERE username = '${SULU_ADMIN_USER}'" 2> /dev/null | grep -q "${SULU_ADMIN_USER}"; then
    echo "Creating admin user '${SULU_ADMIN_USER}'..."
    console bin/adminconsole sulu:security:role:create Admin Sulu || true
    console bin/adminconsole sulu:security:user:create \
        "${SULU_ADMIN_USER}" Admin Sulu "${SULU_ADMIN_EMAIL}" en Admin "${SULU_ADMIN_PASSWORD}"
fi

#* Abhängigkeiten (falls Projekt im Image oder Volume gemountet)
if [ -f "composer.json" ]; then
    echo "Running composer update..."
    composer update --no-dev --optimize-autoloader --no-interaction
fi

#* Datenbank-Migrationen (optional, falls DB-Zugriff nötig für Backup-Config)
# Pre-deploy backup: capture a full restore point (DB + media) before any
# migration runs. Skipped when the DB was just built (nothing to protect).
# backup.sh itself is a no-op unless BACKUP_ENABLED=true, so this is safe to
# call unconditionally when the DB already existed.
if [ "${BACKUP_BEFORE_MIGRATE:-true}" = "true" ] && [ "$fresh_db" = "0" ]; then
    echo "Running pre-deploy backup before migrations..."
    /usr/local/bin/backup || true
fi

echo "Running database migrations..."
php bin/adminconsole doctrine:migrations:migrate --no-interaction --allow-no-migration

#* Suche indexieren
echo "Reindex search..."
php bin/adminconsole cmsig:seal:reindex

# PHP runs in-process via mod_php, so Apache is the only web process.
# Supervise it (and the optional cron daemon) as children and exit as
# soon as either one dies, so Magic Containers restarts the whole
# container instead of leaving it up in a broken state.
apache2-foreground &
httpd_pid=$!

# Periodic backup: only when explicitly enabled and credentials are present.
# Debian cron reads /var/spool/cron/crontabs; job output is redirected to the
# container's stdout (PID 1) so it shows up in the container logs.
crond_pid=""
if [ "${BACKUP_ENABLED:-}" = "true" ] && [ -n "${RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID:-}" ]; then
    : "${BACKUP_SCHEDULE:=0 3 * * *}"
    echo "${BACKUP_SCHEDULE} /usr/local/bin/backup >/proc/1/fd/1 2>&1" | crontab -
    echo "Backup enabled: cron schedule '${BACKUP_SCHEDULE}'."
    cron -f &
    crond_pid=$!
fi

stopping=0
trap 'stopping=1; kill -TERM "$httpd_pid" ${crond_pid:+$crond_pid} 2>/dev/null || true' TERM INT QUIT

while kill -0 "$httpd_pid" 2>/dev/null \
      && { [ -z "$crond_pid" ] || kill -0 "$crond_pid" 2>/dev/null; }; do
    # Interruptible sleep: wait on a background sleep so TERM/INT are handled
    # immediately instead of after the full interval.
    sleep 5 &
    wait $! || true
done

kill -TERM "$httpd_pid" ${crond_pid:+$crond_pid} 2>/dev/null || true
wait || true

if [ "$stopping" = 1 ]; then
    exit 0
fi
echo "ERROR: httpd or cron exited unexpectedly, stopping container." >&2
exit 1
