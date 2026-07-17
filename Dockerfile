FROM php:8.4-fpm-alpine

# Apache fronts PHP-FPM inside the same container: httpd serves static
# files and proxies PHP requests to FPM on 127.0.0.1:9000 (see
# docker/apache.conf). Build deps are only needed to compile the PHP
# extensions; scanelf collects their runtime libraries so the -dev
# packages can be dropped again.
RUN apk add --no-cache apache2 apache2-proxy git unzip su-exec \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
        icu-dev libzip-dev libpng-dev libjpeg-turbo-dev libwebp-dev freetype-dev \
    && docker-php-ext-configure gd --with-jpeg --with-webp --with-freetype \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql intl gd zip exif opcache \
    && runDeps="$(scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
        | tr ',' '\n' | sort -u | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }')" \
    && apk add --no-cache --virtual .run-deps $runDeps \
    && apk del .build-deps

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY docker/apache.conf /etc/apache2/conf.d/zz-app.conf
COPY docker/php.ini /usr/local/etc/php/conf.d/app.ini

# FPM clears the worker environment by default — keep the runtime
# variables from Magic Containers (DATABASE_URL etc.) visible to PHP.
RUN { echo '[www]'; echo 'clear_env = no'; } > /usr/local/etc/php-fpm.d/zz-app.conf

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
RUN chmod +x /entrypoint.sh /usr/local/bin/clear-caches

EXPOSE 80

CMD ["/entrypoint.sh"]
