FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl wget git sudo unzip \
    nginx \
    php8.2-fpm php8.2-cli \
    php8.2-pgsql \
    php8.2-curl \
    php8.2-xml php8.2-mbstring php8.2-zip \
    php8.2-intl \
    postgresql-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Clone FusionPBX
RUN git clone https://github.com/fusionpbx/fusionpbx.git /var/www/fusionpbx

# Create config directory
RUN mkdir -p /etc/fusionpbx \
    && chown -R www-data:www-data /etc/fusionpbx \
    && chmod -R 775 /etc/fusionpbx

# Set web root permissions
RUN chown -R www-data:www-data /var/www/fusionpbx

COPY nginx.conf /etc/nginx/sites-available/default
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
