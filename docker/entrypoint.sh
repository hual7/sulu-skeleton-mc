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

# The persistent volume (mounted at var/) only holds media originals,
# the search index and logs. The Symfony cache lives in APP_CACHE_DIR
# outside the volume — it is per-image-build and must not survive
# deploys. Remove stale cache an older image may have left on the
# volume; leftover root-owned files there would break cache:clear.
rm -rf var/cache

# Shared-volume mode: when one volume is shared between app and db
# (mounted e.g. at /data in both), each container must stay inside its
# own subdirectory. Set APP_DATA_DIR (e.g. /data/app) and var/ becomes
# a symlink into it; the db container gets its own subdir via
# --datadir (see README). Not needed when a dedicated volume is
# mounted directly at /var/www/html/var.
if [ -n "${APP_DATA_DIR:-}" ] && [ ! -L var ]; then
    if mountpoint -q var; then
        echo "WARNING: APP_DATA_DIR is set but a volume is mounted at var/ — ignoring APP_DATA_DIR." >&2
    else
        mkdir -p "$APP_DATA_DIR"
        rm -rf var
        ln -s "$APP_DATA_DIR" var
    fi
fi

# var/ may be a freshly mounted, empty volume — recreate the layout and
# make it writable for www-data before running any console command.
# chown covers volume backends with working ownership; chmod covers the
# ones that force ownership to root (see umask note above).
mkdir -p "$APP_CACHE_DIR" var/log var/share var/indexes var/sessions var/storage public/uploads public/bundles
chown www-data:www-data "$APP_CACHE_DIR" var var/log var/share var/indexes var/sessions var/storage public/uploads public/bundles || true
chmod -R a+rwX "$APP_CACHE_DIR" var public/uploads public/bundles

console() {
    runuser -u www-data -- php "$@"
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

exec apache2-foreground
