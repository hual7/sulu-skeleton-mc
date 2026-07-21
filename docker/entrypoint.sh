#!/bin/sh
set -e

# Used as the image ENTRYPOINT; the CMD ("apache2-foreground") is passed as "$@".
# The Sulu setup runs only when we are actually about to start Apache, then the
# script hands off with `exec "$@"` so Apache runs as PID 1 and manages its own
# signals and graceful shutdown. `docker run <image> bash` (or the console/
# backup helpers) skip the setup and run straight away.
if [ "${1:-}" = "apache2-foreground" ]; then

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
    # sulu:build publishes the homepage, which makes the Bunny CDN bundle purge
    # the cache. A failing purge (missing/invalid BUNNY_API_KEY, or a transient
    # Bunny API error) makes the command exit non-zero even though the site was
    # built — the CDN purge is best-effort and must never block the first start.
    # Only abort if the schema was genuinely not created.
    echo "Empty database detected, running sulu:build prod..."
    if ! console bin/adminconsole sulu:build prod --no-interaction; then
        if db_built; then
            echo "WARNING: sulu:build exited non-zero but the schema exists — likely" >&2
            echo "         the CDN cache purge (check BUNNY_API_KEY). Continuing." >&2
        else
            echo "ERROR: sulu:build failed and no schema was created." >&2
            exit 1
        fi
    fi
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

# sulu:build prod does not create any user (only the dev target does). Creating
# the user also triggers a CDN cache purge, so tolerate a failing purge the same
# way as the build: verify the user exists afterwards instead of trusting the
# exit code. role:create exits non-zero if the role already exists (|| true).
user_exists() {
    console bin/adminconsole doctrine:query:sql \
        "SELECT username FROM se_users WHERE username = '${SULU_ADMIN_USER}'" 2>/dev/null \
        | grep -q "${SULU_ADMIN_USER}"
}
if ! user_exists; then
    echo "Creating admin user '${SULU_ADMIN_USER}'..."
    console bin/adminconsole sulu:security:role:create Admin Sulu || true
    console bin/adminconsole sulu:security:user:create \
        "${SULU_ADMIN_USER}" Admin Sulu "${SULU_ADMIN_EMAIL}" en Admin "${SULU_ADMIN_PASSWORD}" || true
    if ! user_exists; then
        echo "ERROR: admin user '${SULU_ADMIN_USER}' could not be created." >&2
        exit 1
    fi
fi

# Dependencies are installed and the autoloader is dumped at build time
# (see Dockerfile); no composer step runs here. Running `composer update` at
# container start would need network access to Packagist, change installed
# versions non-deterministically, and abort the whole start on any failure.

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
# Best-effort: a stale or failed search index must not block the container from
# starting (it can be rebuilt later), and reindex can also trigger a CDN purge.
echo "Reindex search..."
php bin/adminconsole cmsig:seal:reindex \
    || echo "WARNING: search reindex failed (index may be stale); continuing." >&2

# Periodic backup: only when explicitly enabled and credentials are present.
# Debian cron daemonises into the background (no -f); its job redirects output
# to PID 1 (Apache) so it surfaces in the container logs. Best-effort — if cron
# dies the site stays up; backups are not worth restarting the container for.
if [ "${BACKUP_ENABLED:-}" = "true" ] && [ -n "${RCLONE_CONFIG_BUNNY_ACCESS_KEY_ID:-}" ]; then
    : "${BACKUP_SCHEDULE:=0 3 * * *}"
    echo "${BACKUP_SCHEDULE} /usr/local/bin/backup >/proc/1/fd/1 2>&1" | crontab -
    echo "Backup enabled: cron schedule '${BACKUP_SCHEDULE}'."
    cron
fi

fi  # end of the apache2-foreground setup

# Hand the container over to Apache (mod_php) as PID 1 — it runs in the
# foreground and manages its own signals and graceful shutdown. STOPSIGNAL is
# the php:apache default (SIGWINCH, graceful), so no override is needed.
exec "$@"
