#!/bin/bash
set -e

echo "🔧 Fixing permissions..."
mkdir -p /etc/fusionpbx
chown -R www-data:www-data /etc/fusionpbx
chmod -R 775 /etc/fusionpbx

echo "⏳ Waiting for PostgreSQL..."
until pg_isready -h "${DB_HOST:-postgres}" -p "${DB_PORT:-5432}" -U "${DB_USERNAME:-fusionpbx}" > /dev/null 2>&1; do
  echo "   PostgreSQL not ready yet... retrying in 2s"
  sleep 2
done
echo "✅ PostgreSQL is ready!"

echo "🔍 Checking if FusionPBX schema exists..."
TABLE_COUNT=$(php -r "
  \$pdo = new PDO(
    'pgsql:host=${DB_HOST:-postgres};port=${DB_PORT:-5432};dbname=${DB_NAME:-fusionpbx}',
    '${DB_USERNAME:-fusionpbx}',
    '${DB_PASSWORD}'
  );
  \$result = \$pdo->query(\"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'\");
  echo \$result->fetchColumn();
")

if [ "$TABLE_COUNT" -eq "0" ]; then
  echo "🚀 DB is empty — running installer..."

  # ❌ Remove config so installer thinks it's fresh
  rm -f /etc/fusionpbx/config.conf
  rm -f /usr/local/etc/fusionpbx/config.conf

  # Start services
  service php8.2-fpm start
  nginx &
  sleep 5

  echo "🌐 Step 1 - GET installer to get session cookie..."
  curl -s -c /tmp/cookies.txt -o /tmp/install_get.html \
    "http://localhost/core/install/install.php"
  echo "GET response size: $(wc -c < /tmp/install_get.html) bytes"

  echo "🌐 Step 2 - POST with admin credentials..."
  curl -s -b /tmp/cookies.txt -c /tmp/cookies.txt \
    -L -o /tmp/install_output.html \
    --data "admin_username=admin&admin_password=StrongPassword123&database_username=${DB_USERNAME:-fusionpbx}&database_password=${DB_PASSWORD}&database_host=${DB_HOST:-postgres}&database_port=${DB_PORT:-5432}&database_name=${DB_NAME:-fusionpbx}&domain_name=localhost" \
    "http://localhost/core/install/install.php"
  echo "POST response size: $(wc -c < /tmp/install_output.html) bytes"
  cat /tmp/install_output.html | grep -i "error\|success\|complete\|installed\|warning" | head -20

  sleep 5

  TABLE_COUNT2=$(php -r "
    \$pdo = new PDO(
      'pgsql:host=${DB_HOST:-postgres};port=${DB_PORT:-5432};dbname=${DB_NAME:-fusionpbx}',
      '${DB_USERNAME:-fusionpbx}',
      '${DB_PASSWORD}'
    );
    \$result = \$pdo->query(\"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'\");
    echo \$result->fetchColumn();
  ")
  echo "📊 Tables created: ${TABLE_COUNT2}"

  nginx -s stop 2>/dev/null || true
  sleep 2
else
  echo "✅ DB already has ${TABLE_COUNT} tables, skipping installer."
fi

echo "📝 Writing /etc/fusionpbx/config.conf..."
mkdir -p /etc/fusionpbx
cat > /etc/fusionpbx/config.conf << EOF
database.0.type = pgsql
database.0.host = ${DB_HOST:-postgres}
database.0.port = ${DB_PORT:-5432}
database.0.name = ${DB_NAME:-fusionpbx}
database.0.username = ${DB_USERNAME:-fusionpbx}
database.0.password = ${DB_PASSWORD}
EOF
chown www-data:www-data /etc/fusionpbx/config.conf
chmod 660 /etc/fusionpbx/config.conf
echo "✅ config.conf written!"

echo "🔧 Fixing web root permissions..."
chown -R www-data:www-data /var/www/fusionpbx

echo "✅ Starting PHP-FPM..."
service php8.2-fpm start

echo "✅ Starting Nginx..."
exec nginx -g "daemon off;"
