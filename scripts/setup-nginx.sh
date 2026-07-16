#!/bin/bash
# Установка nginx reverse proxy для Grist (+ Keycloak при mode=new).
# Запуск: sudo ./scripts/setup-nginx.sh
# Читает AUTH_DOMAIN и GRIST_DOMAIN из /opt/grist-sso/.env (или задайте DEPLOY_DIR).
# KEYCLOAK_MODE=existing → только vhost Grist (auth на другом хосте).

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/grist-sso}"
ENV_FILE="$DEPLOY_DIR/.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_OUT="/etc/nginx/sites-available/grist-sso.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1" >&2; }
err() { echo -e "${RED}✗${NC} $1" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Запустите с sudo: sudo $0"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    err "Нет файла $ENV_FILE — сначала выполните deploy.sh"
    exit 1
fi

read_env() {
    local key="$1"
    grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | sed "s/^${key}=//"
}

AUTH_DOMAIN=$(read_env AUTH_DOMAIN)
GRIST_DOMAIN=$(read_env GRIST_DOMAIN)
KEYCLOAK_MODE="${KEYCLOAK_MODE:-$(read_env KEYCLOAK_MODE)}"
KEYCLOAK_MODE="${KEYCLOAK_MODE:-new}"

if [[ -z "$GRIST_DOMAIN" ]]; then
    err "В $ENV_FILE должен быть GRIST_DOMAIN"
    exit 1
fi

if [[ "$KEYCLOAK_MODE" == "new" && -z "$AUTH_DOMAIN" ]]; then
    err "В $ENV_FILE должен быть AUTH_DOMAIN (mode=new)"
    exit 1
fi

if [[ "$KEYCLOAK_MODE" == "existing" ]]; then
    TEMPLATE="$REPO_ROOT/nginx/grist-only.conf.template"
else
    TEMPLATE="$REPO_ROOT/nginx/grist-sso.conf.template"
fi

if [[ ! -f "$TEMPLATE" ]]; then
    err "Нет шаблона: $TEMPLATE"
    exit 1
fi

SSL_CERT_AUTH="/etc/letsencrypt/live/${AUTH_DOMAIN}/fullchain.pem"
SSL_KEY_AUTH="/etc/letsencrypt/live/${AUTH_DOMAIN}/privkey.pem"
SSL_CERT_GRIST="/etc/letsencrypt/live/${GRIST_DOMAIN}/fullchain.pem"
SSL_KEY_GRIST="/etc/letsencrypt/live/${GRIST_DOMAIN}/privkey.pem"

check_cert() {
    [[ -f "$1" && -f "$2" ]]
}

if [[ "$KEYCLOAK_MODE" == "new" ]]; then
    if ! check_cert "$SSL_CERT_AUTH" "$SSL_KEY_AUTH"; then
        warn "Не найдены сертификаты для $AUTH_DOMAIN:"
        warn "  $SSL_CERT_AUTH"
        warn "Выпустите, например:"
        warn "  certbot certonly --nginx -d $AUTH_DOMAIN"
        exit 1
    fi
fi

if ! check_cert "$SSL_CERT_GRIST" "$SSL_KEY_GRIST"; then
    warn "Не найдены сертификаты для $GRIST_DOMAIN:"
    warn "  $SSL_CERT_GRIST"
    warn "  certbot certonly --nginx -d $GRIST_DOMAIN"
    exit 1
fi

if ! command -v nginx &>/dev/null; then
    err "nginx не установлен: apt-get install -y nginx"
    exit 1
fi

tmp=$(mktemp)
if [[ "$KEYCLOAK_MODE" == "existing" ]]; then
    sed \
        -e "s|__GRIST_DOMAIN__|${GRIST_DOMAIN}|g" \
        -e "s|__SSL_CERT_GRIST__|${SSL_CERT_GRIST}|g" \
        -e "s|__SSL_KEY_GRIST__|${SSL_KEY_GRIST}|g" \
        "$TEMPLATE" > "$tmp"
else
    sed \
        -e "s|__AUTH_DOMAIN__|${AUTH_DOMAIN}|g" \
        -e "s|__GRIST_DOMAIN__|${GRIST_DOMAIN}|g" \
        -e "s|__SSL_CERT_AUTH__|${SSL_CERT_AUTH}|g" \
        -e "s|__SSL_KEY_AUTH__|${SSL_KEY_AUTH}|g" \
        -e "s|__SSL_CERT_GRIST__|${SSL_CERT_GRIST}|g" \
        -e "s|__SSL_KEY_GRIST__|${SSL_KEY_GRIST}|g" \
        "$TEMPLATE" > "$tmp"
fi

cp "$tmp" "$NGINX_OUT"
rm -f "$tmp"
log "Записан: $NGINX_OUT (KEYCLOAK_MODE=$KEYCLOAK_MODE)"

if [[ -L /etc/nginx/sites-enabled/default ]]; then
    warn "Удалите ссылку default, если 404 от дефолтного vhost: rm /etc/nginx/sites-enabled/default"
fi

ln -sf "$NGINX_OUT" /etc/nginx/sites-enabled/grist-sso.conf
log "Включён: /etc/nginx/sites-enabled/grist-sso.conf"

nginx -t
systemctl reload nginx
log "nginx перезагружен."
echo ""
echo "Проверка:"
if [[ "$KEYCLOAK_MODE" == "new" ]]; then
    echo "  curl -sI https://${AUTH_DOMAIN} | head -3"
fi
echo "  curl -sI https://${GRIST_DOMAIN} | head -3"
