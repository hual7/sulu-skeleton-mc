FROM php:8.4-apache

RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip \
        libicu-dev libzip-dev libpng-dev libjpeg62-turbo-dev libwebp-dev libfreetype6-dev \
    && docker-php-ext-configure gd --with-jpeg --with-webp --with-freetype \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql intl gd zip exif opcache \
    && a2enmod rewrite headers \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf

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
RUN chmod +x /entrypoint.sh

EXPOSE 80

CMD ["/entrypoint.sh"]
