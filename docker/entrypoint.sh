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
    su-exec www-data php "$@"
}

echo "Preparing application (cache, assets, media dirs)..."
console bin/adminconsole cache:clear
console bin/websiteconsole cache:clear
console bin/console assets:install public
console bin/adminconsole sulu:media:init

echo "Waiting for database..."
i=0
until console bin/adminconsole doctrine:query:sql "SELECT 1" > /dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        echo "ERROR: database was not reachable after 60 seconds, giving up." >&2
        exit 1
    fi
    sleep 1
done
echo "Database is ready."

if ! console bin/adminconsole doctrine:query:sql "SELECT 1 FROM se_users LIMIT 1" > /dev/null 2>&1; then
    echo "Empty database detected, running sulu:build prod..."
    console bin/adminconsole sulu:build prod --no-interaction
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

# PHP-FPM daemonizes into the background (-D overrides the base
# image's daemonize=no), then Apache takes over as PID 1.
mkdir -p /run/apache2
php-fpm -D
exec httpd -DFOREGROUND
