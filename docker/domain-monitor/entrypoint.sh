#!/bin/bash
set -e

echo "[Entrypoint] Initializing Domain Monitor..."

# 1. Sync source from read-only Nix store mount (/app/src) to writable webroot
if [ -d "/usr/src/domain-monitor" ]; then
    echo "[Entrypoint] Syncing source code..."
    cp -rn /usr/src/domain-monitor/. /var/www/html/

    # rsync updates with write permissions forced
    rsync -av --no-o --no-g --chmod=Du+w,Fu+w --exclude '.git' --exclude 'config.php' --exclude '.env' /usr/src/domain-monitor/ /var/www/html/
fi

# 2. Handle Permissions
# Create composer cache directory
mkdir -p /var/www/.composer
chown -R www-data:www-data /var/www/.composer

echo "[Entrypoint] Setting permissions..."
# Ensure www-data owns the webroot and it is writable
chown -R www-data:www-data /var/www/html
chmod -R u+w /var/www/html

# 3. Install/Update PHP Dependencies
if [ -f "composer.json" ]; then
    echo "[Entrypoint] Running composer install..."
    su -s /bin/bash www-data -c "composer install --no-dev --optimize-autoloader --no-interaction"
fi

# 4. Generate .env from Docker Environment Variables safely
echo "[Entrypoint] Generating .env from environment variables..."
# FILTERING: Dump variables starting with CI_, APP_, or DB_
# This keeps the necessary config while excluding system vars that break the parser.
printenv | grep -E '^(CI_|APP_|DB_)' >/var/www/html/.env

# Ensure .env is readable by the app
chown www-data:www-data /var/www/html/.env

exec "$@"
