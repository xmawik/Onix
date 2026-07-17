#!/usr/bin/env bash
#
# ONIX Panel - Automated installer for Ubuntu/Debian VDS
# Run as root:  sudo bash deploy.sh
#
set -euo pipefail

# ---------- Colors ----------
if [ -t 1 ]; then
    C_BLUE='\033[0;34m'; C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'; C_NC='\033[0m'
else
    C_BLUE=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_NC=''
fi

info()  { echo -e "${C_BLUE}[ONIX]${C_NC} $*"; }
ok()    { echo -e "${C_GREEN}[OK]${C_NC} $*"; }
warn()  { echo -e "${C_YELLOW}[!]${C_NC} $*"; }
err()   { echo -e "${C_RED}[ERROR]${C_NC} $*" >&2; }

abort() { err "$*"; exit 1; }

# ---------- Must run as root ----------
[ "$(id -u)" -eq 0 ] || abort "Run this script as root (sudo bash deploy.sh)"

# ---------- Config (with defaults / prompts) ----------
PHP_VER="8.2"
DB_NAME="onix"
DB_USER="onix"
INSTALL_DIR="/var/www/onix"
REPO_URL="https://github.com/xmawik/Onix.git"

read -rp "$(echo -e "${C_YELLOW}Domain or server IP for the panel: ${C_NC}")" APP_URL_INPUT
APP_URL="${APP_URL_INPUT:-$(curl -s ifconfig.me || hostname -I | awk '{print $1}')}"

read -rp "$(echo -e "${C_YELLOW}Database password for user '${DB_USER}': ${C_NC}")" -s DB_PASS
echo
[ -n "$DB_PASS" ] || abort "Database password cannot be empty"

read -rp "$(echo -e "${C_YELLOW}Admin email: ${C_NC}")" ADMIN_EMAIL
read -rp "$(echo -e "${C_YELLOW}Admin username: ${C_NC}")" ADMIN_USER
read -rp "$(echo -e "${C_YELLOW}Admin password (min 8 chars): ${C_NC}")" -s ADMIN_PASS
echo
[ -n "$ADMIN_USER" ] && [ -n "$ADMIN_EMAIL" ] && [ "${#ADMIN_PASS}" -ge 8 ] \
    || abort "Admin username/email required and password must be at least 8 characters"

read -rp "$(echo -e "${C_YELLOW}Announcement banner text (leave empty to hide): ${C_NC}")" APP_ANNOUNCEMENT
read -rp "$(echo -e "${C_YELLOW}Support URL (leave empty to hide): ${C_NC}")" APP_SUPPORT_URL

# ---------- 1. System & packages ----------
info "Updating system and installing packages..."
apt-get update -y
apt-get upgrade -y

export DEBIAN_FRONTEND=noninteractive
apt-get install -y nginx mariadb-server redis-server curl tar unzip git \
    php${PHP_VER} php${PHP_VER}-cli php${PHP_VER}-common php${PHP_VER}-curl \
    php${PHP_VER}-fpm php${PHP_VER}-gd php${PHP_VER}-mbstring php${PHP_VER}-mysql \
    php${PHP_VER}-xml php${PHP_VER}-zip php${PHP_VER}-bcmath php${PHP_VER}-intl \
    php${PHP_VER}-gmp php${PHP_VER}-redis supervisor

info "Installing Node.js 22 + Yarn..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g yarn

info "Installing Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
# Make sure CLI php is the one we installed
update-alternatives --set php /usr/bin/php${PHP_VER} 2>/dev/null || true
ok "Packages installed"

# ---------- 2. Database ----------
info "Configuring MariaDB database '${DB_NAME}'..."
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
ok "Database ready"

# ---------- 3. Code ----------
info "Preparing code in ${INSTALL_DIR}..."
if [ -d "${INSTALL_DIR}/.git" ]; then
    warn "${INSTALL_DIR} already exists — resetting and pulling latest changes"
    cd "$INSTALL_DIR"
    git checkout -f
    git pull --ff-only || git pull
elif [ -d "$INSTALL_DIR" ]; then
    warn "${INSTALL_DIR} exists but is not a git repo — continuing in place"
    cd "$INSTALL_DIR"
else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# ---------- 4. Dependencies & build (BEFORE artisan commands) ----------
info "Installing PHP dependencies..."
composer install --no-dev --optimize-autoloader

info "Installing JS dependencies and building assets..."
# public/assets does not exist in a fresh clone; create it so the 'clean'
# step in build:production (which does 'cd public/assets') does not fail.
mkdir -p public/assets
yarn install
yarn build:production
ok "Build complete"

# ---------- 5. Environment ----------
if [ -f .env ]; then
    warn ".env already present — keeping it, only (re)generating app key if missing"
else
    info "Writing .env from example..."
    cp .env.example .env
fi
php artisan key:generate --force

# Inject DB + custom settings into .env (idempotent)
set_env() {
    local key="$1" val="$2"
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${val}|" .env
    else
        echo "${key}=${val}" >> .env
    fi
}
set_env APP_URL "http://${APP_URL}"
set_env DB_CONNECTION "mysql"
set_env DB_HOST "127.0.0.1"
set_env DB_PORT "3306"
set_env DB_DATABASE "${DB_NAME}"
set_env DB_USERNAME "${DB_USER}"
set_env DB_PASSWORD "${DB_PASS}"
set_env APP_THEME "pterodactyl"
set_env APP_ANNOUNCEMENT "\"${APP_ANNOUNCEMENT}\""
set_env APP_SUPPORT_URL "\"${APP_SUPPORT_URL}\""

info "Running migrations and seeds..."
php artisan migrate --seed --force

info "Creating admin user '${ADMIN_USER}'..."
php artisan p:user:make <<PHP
${ADMIN_EMAIL}
${ADMIN_USER}
${ADMIN_PASS}
${ADMIN_PASS}
y
PHP

# ---------- 6. Permissions & cache ----------
info "Setting permissions and clearing cache..."
chown -R www-data:www-data "$INSTALL_DIR"
chmod -R 755 "$INSTALL_DIR"
php artisan storage:link
php artisan view:clear
php artisan config:clear
php artisan route:clear
ok "Permissions set"

# ---------- 7. Nginx ----------
info "Configuring Nginx for ${APP_URL}..."
cat > /etc/nginx/sites-available/onix <<NGINX
server {
    listen 80;
    server_name ${APP_URL};
    root ${INSTALL_DIR}/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }

    location ~ /\.(?!well-known).* { deny all; }
}
NGINX
ln -sf /etc/nginx/sites-available/onix /etc/nginx/sites-enabled/onix
# Remove default site to avoid conflicts
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
ok "Nginx configured"

# ---------- 8. Queue worker (Supervisor) ----------
info "Setting up Supervisor queue worker..."
cat > /etc/supervisor/conf.d/onix-worker.conf <<SUP
[program:onix-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${INSTALL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
autostart=true
autorestart=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=${INSTALL_DIR}/storage/logs/worker.log
SUP
supervisorctl reread
supervisorctl update
supervisorctl start onix-worker:*
ok "Queue worker running"

# ---------- Done ----------
echo
ok "==============================================="
ok " ONIX Panel installed successfully!"
ok " URL:     http://${APP_URL}"
ok " Login:   ${ADMIN_USER} / (your password)"
ok "==============================================="
warn "Optional: enable HTTPS with:"
warn "   apt install -y certbot python3-certbot-nginx"
warn "   certbot --nginx -d ${APP_URL}"
echo
