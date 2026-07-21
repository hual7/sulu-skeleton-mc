FROM php:8.4-apache

# Debian-based image running PHP as an Apache module (mod_php). Structure follows
# the official docker-library images (e.g. wordpress:php8.4-apache): build deps
# are installed, used to compile the extensions, then purged again — the shared
# libraries the extensions actually link against are detected via ldd and kept.

# Persistent runtime dependencies: media processing (Sulu preview generation) and
# the backup helper (rclone + mariadb-dump).
RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		git unzip gosu cron \
		rclone mariadb-client \
		ffmpeg ghostscript imagemagick \
	; \
	rm -rf /var/lib/apt/lists/*

# PHP extensions Sulu needs. Build deps are purged afterwards; the runtime libs
# the extensions link against are detected with ldd and re-marked "manual" so
# they survive the purge.
RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	\
	apt-get update; \
	apt-get install -y --no-install-recommends \
		libfreetype6-dev \
		libicu-dev \
		libjpeg-dev \
		libmagickwand-dev \
		libpng-dev \
		libwebp-dev \
		libzip-dev \
	; \
	\
	docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
	docker-php-ext-install -j "$(nproc)" \
		exif \
		gd \
		intl \
		opcache \
		pdo_mysql \
		zip \
	; \
	pecl install imagick-3.8.1; \
	docker-php-ext-enable imagick; \
	rm -r /tmp/pear; \
	\
	extDir="$(php -r 'echo ini_get("extension_dir");')"; \
	[ -d "$extDir" ]; \
# reset apt-mark's "manual" list so "purge --auto-remove" drops the build deps
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark; \
	ldd "$extDir"/*.so \
		| awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
		| sort -u \
		| xargs -r dpkg-query --search \
		| cut -d: -f1 \
		| sort -u \
		| xargs -rt apt-mark manual; \
	\
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*; \
	\
# sanity checks: every extension lib resolves and PHP starts without warnings
	! { ldd "$extDir"/*.so | grep 'not found'; }; \
	err="$(php --version 3>&1 1>&2 2>&3)"; \
	[ -z "$err" ]

# Recommended opcache settings + container-friendly error logging (to stderr,
# never to the response body).
RUN set -eux; \
	{ \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=10000'; \
		echo 'opcache.revalidate_freq=2'; \
	} > "$PHP_INI_DIR/conf.d/opcache-recommended.ini"; \
	{ \
		echo 'display_errors = Off'; \
		echo 'display_startup_errors = Off'; \
		echo 'log_errors = On'; \
		echo 'error_log = /dev/stderr'; \
	} > "$PHP_INI_DIR/conf.d/error-logging.ini"

# Apache modules + real client IPs behind the Bunny edge proxy (mod_remoteip),
# with %a in the access log so it shows the client, not the proxy.
RUN set -eux; \
	a2enmod rewrite headers expires remoteip; \
	{ \
		echo 'RemoteIPHeader X-Forwarded-For'; \
		echo 'RemoteIPInternalProxy 10.0.0.0/8'; \
		echo 'RemoteIPInternalProxy 172.16.0.0/12'; \
		echo 'RemoteIPInternalProxy 192.168.0.0/16'; \
		echo 'RemoteIPInternalProxy 169.254.0.0/16'; \
		echo 'RemoteIPInternalProxy 127.0.0.0/8'; \
	} > /etc/apache2/conf-available/remoteip.conf; \
	a2enconf remoteip; \
	find /etc/apache2 -type f -name '*.conf' -exec sed -ri 's/([[:space:]]*LogFormat[[:space:]]+"[^"]*)%h([^"]*")/\1%a\2/g' '{}' +

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf
COPY docker/php.ini /usr/local/etc/php/conf.d/app.ini

# Keep the Symfony cache outside of /var/www/html/var so a persistent volume
# mounted there never carries stale cache across deploys.
ENV APP_CACHE_DIR=/var/cache/sulu

WORKDIR /var/www/html

COPY composer.json composer.lock symfony.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-progress

COPY . .

# Config is intentionally NOT cached at build time so that runtime environment
# variables from Magic Containers take effect (see entrypoint).
RUN composer dump-autoload --optimize --no-dev \
	&& mkdir -p var public/uploads \
	&& chown -R www-data:www-data var public/uploads

COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY docker/clear-caches.sh /usr/local/bin/clear-caches
COPY docker/backup.sh /usr/local/bin/backup
COPY docker/runtime-state.sh /usr/local/lib/runtime-state.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/clear-caches /usr/local/bin/backup

EXPOSE 80

# The entrypoint runs the Sulu setup, then `exec "$@"` hands off to the CMD so
# Apache runs as PID 1 (proper signal handling / graceful shutdown).
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2-foreground"]
