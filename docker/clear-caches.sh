#!/bin/sh
# Clears all regenerable caches. Safe to run on a live container.
# Does NOT touch media originals (var/storage), the search index
# (var/indexes) or the database.
set -e

cd /var/www/html

echo "Clearing HTTP page cache (var/share)..."
rm -rf var/share/*/http_cache

echo "Clearing stale volume cache leftovers (var/cache)..."
rm -rf var/cache

echo "Rebuilding Symfony cache..."
runuser -u www-data -- php bin/adminconsole cache:clear
runuser -u www-data -- php bin/websiteconsole cache:clear

echo "Done."
