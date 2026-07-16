#!/bin/sh
set -e

cd /var/www/html

: "${SULU_ADMIN_USER:=admin}"
: "${SULU_ADMIN_PASSWORD:=admin}"
: "${SULU_ADMIN_EMAIL:=admin@example.com}"

# var/ may be a freshly mounted, empty volume — recreate the layout and
# make it writable for www-data before running any console command.
mkdir -p var/cache var/log var/share var/indexes var/sessions public/uploads public/bundles
chown www-data:www-data var var/cache var/log var/share var/indexes var/sessions public/uploads public/bundles

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
