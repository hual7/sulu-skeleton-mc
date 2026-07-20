FROM php:8.4-apache

# Debian-based image running PHP as an Apache module (mod_php): Apache
# serves static files and executes PHP in-process, no separate FPM
# daemon. The -dev packages are only needed to compile the PHP
# extensions but are kept installed so their runtime shared libraries
# stay available to the built extensions (apt has no scanelf-style
# runtime-dep detection).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip gosu cron rclone mariadb-client ffmpeg ghostscript imagemagick \
        libicu-dev libzip-dev libpng-dev libjpeg62-turbo-dev libwebp-dev libfreetype6-dev libmagickwand-dev \
    && docker-php-ext-configure gd --with-jpeg --with-webp --with-freetype \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql intl gd zip exif opcache \
    && printf '\n' | pecl install imagick \
    && docker-php-ext-enable imagick \
    && a2enmod rewrite headers \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf
COPY docker/php.ini /usr/local/etc/php/conf.d/app.ini

# Keep the Symfony cache outside of /var/www/html/var so a persistent
# volume mounted there never carries stale cache across deploys.
ENV APP_CACHE_DIR=/var/cache/sulu

WORKDIR /var/www/html

COPY composer.json composer.lock symfony.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-progress

COPY . .

# Config is intentionally NOT cached at build time so that runtime
# environment variables from Magic Containers take effect (see entrypoint).
RUN composer dump-autoload --optimize --no-dev \
    && mkdir -p var public/uploads \
    && chown -R www-data:www-data var public/uploads

COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/clear-caches.sh /usr/local/bin/clear-caches
COPY docker/backup.sh /usr/local/bin/backup
COPY docker/runtime-state.sh /usr/local/lib/runtime-state.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/clear-caches /usr/local/bin/backup

EXPOSE 80

# The php:apache base image sets STOPSIGNAL SIGWINCH (Apache's graceful
# stop), which the entrypoint shell would ignore — docker stop would
# hang and SIGKILL after the grace period. TERM is handled by the
# entrypoint's supervise loop.
STOPSIGNAL SIGTERM

CMD ["/entrypoint.sh"]
