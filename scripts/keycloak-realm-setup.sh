#!/bin/bash

################################################################################
# Keycloak Realm и OIDC Client Setup
# Создание realm "grist" и OIDC client "grist-client" через Admin API
################################################################################

set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Параметры из env
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://grist-sso-keycloak:8080}"
GRIST_DOMAIN="${GRIST_DOMAIN}"
AUTH_DOMAIN="${AUTH_DOMAIN}"
GRIST_OIDC_CLIENT_SECRET_FILE="${GRIST_OIDC_CLIENT_SECRET_FILE:-/tmp/grist-client-secret.txt}"

################################################################################
# Функции
################################################################################

# Все сообщения — в stderr, чтобы stdout оставался только для данных в $(...)
log_info() {
    echo -e "${BLUE}ℹ${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}✅${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}⚠${NC}  $1" >&2
}

log_error() {
    echo -e "${RED}❌${NC} $1" >&2
    exit 1
}

################################################################################
# Получение admin token
################################################################################

get_admin_token() {
    log_info "Получение admin token из Keycloak..."

    local response=$(curl -s -X POST \
        "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=$KEYCLOAK_ADMIN" \
        -d "password=$KEYCLOAK_ADMIN_PASSWORD")

    local token=$(echo "$response" | jq -r '.access_token // empty')

    if [[ -z "$token" ]]; then
        echo "Ответ Keycloak: $response" >&2
        log_error "Не удалось получить admin token"
    fi

    echo "$token"
}

################################################################################
# Создание realm
################################################################################

# SMTP отдельным PUT: встроенный smtpServer в POST иногда даёт 400 без поля .error,
# скрипт ошибочно считал успех; плюс jq безопасно кодирует пароль.
update_realm_smtp() {
    local token="$1"
    log_info "Настройка SMTP для realm 'grist'..."

    local realm_json merged put_tmp http_code put_body
    realm_json=$(curl -s -H "Authorization: Bearer $token" "$KEYCLOAK_URL/admin/realms/grist")
    if [[ -z "$realm_json" ]] || ! echo "$realm_json" | jq -e . >/dev/null 2>&1; then
        log_warning "Не удалось прочитать realm для SMTP (пропуск)"
        return 0
    fi

    local port_num="${EMAIL_PORT:-587}"
    [[ "$port_num" =~ ^[0-9]+$ ]] || port_num=587

    merged=$(echo "$realm_json" | jq \
        --arg h "$EMAIL_HOST" \
        --argjson p "$port_num" \
        --arg u "$EMAIL_USER" \
        --arg pw "$EMAIL_PASSWORD" \
        '.smtpServer = {
            host: $h,
            port: $p,
            auth: true,
            starttls: true,
            user: $u,
            password: $pw,
            from: $u
        }') || {
        log_warning "Не удалось собрать JSON SMTP (jq). Настройте SMTP вручную в админке Keycloak."
        return 0
    }

    put_tmp=$(mktemp)
    http_code=$(curl -sS -o "$put_tmp" -w "%{http_code}" -X PUT \
        "$KEYCLOAK_URL/admin/realms/grist" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$merged")
    put_body=$(cat "$put_tmp")
    rm -f "$put_tmp"

    if [[ "$http_code" == "204" ]] || [[ "$http_code" == "200" ]]; then
        log_success "SMTP для realm 'grist' настроен"
    else
        log_warning "SMTP не применён (HTTP $http_code). Настройте вручную: Realm grist → Realm settings → Email. Ответ: $put_body"
    fi
}

create_realm() {
    local token="$1"

    log_info "Создание realm 'grist' (без SMTP в POST — он добавляется отдельно)..."

    local tmp http_code response err_txt verify
    tmp=$(mktemp)
    http_code=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST \
        "$KEYCLOAK_URL/admin/realms" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{
            "realm": "grist",
            "enabled": true,
            "displayName": "Grist",
            "loginTheme": "keycloak",
            "emailTheme": "keycloak",
            "accessTokenLifespan": 3600,
            "refreshTokenLifespan": 604800,
            "offlineSessionIdleTimeout": 2592000
        }')
    response=$(cat "$tmp")
    rm -f "$tmp"

    if [[ "$http_code" == "201" ]] || [[ "$http_code" == "204" ]]; then
        log_success "Realm 'grist' создан (HTTP $http_code)"
    elif [[ "$http_code" == "409" ]] || echo "$response" | grep -qi 'exists\|Conflict'; then
        log_info "Realm 'grist' уже существует (HTTP $http_code)"
    else
        err_txt=$(echo "$response" | jq -r '.error_description // .errorMessage // .error // empty' 2>/dev/null || true)
        echo "Ответ Keycloak при создании realm (HTTP $http_code): $response" >&2
        log_error "Ошибка при создании realm: ${err_txt:-HTTP $http_code}"
    fi

    verify=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" "$KEYCLOAK_URL/admin/realms/grist")
    if [[ "$verify" != "200" ]]; then
        log_error "Realm 'grist' недоступен после POST (GET → HTTP $verify). Проверьте логи Keycloak."
    fi

    update_realm_smtp "$token"
}

################################################################################
# Создание OIDC Client
################################################################################

create_oidc_client() {
    local token="$1"

    log_info "Создание OIDC client 'grist-client'..."

    # ClientRepresentation: поле publicClient, не "public"; protocol — openid-connect
    local tmp http_code response client_id err_txt
    tmp=$(mktemp)
    http_code=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST \
        "$KEYCLOAK_URL/admin/realms/grist/clients" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{
            "clientId": "grist-client",
            "protocol": "openid-connect",
            "enabled": true,
            "publicClient": false,
            "bearerOnly": false,
            "standardFlowEnabled": true,
            "directAccessGrantsEnabled": true,
            "serviceAccountsEnabled": false,
            "authorizationServicesEnabled": false,
            "redirectUris": [
                "https://'$GRIST_DOMAIN'/oauth2/callback"
            ],
            "webOrigins": [
                "https://'$GRIST_DOMAIN'"
            ],
            "rootUrl": "https://'$GRIST_DOMAIN'",
            "baseUrl": "https://'$GRIST_DOMAIN'"
        }')
    response=$(cat "$tmp")
    rm -f "$tmp"

    client_id=$(echo "$response" | jq -r '.id // empty')

    if [[ -n "$client_id" ]]; then
        log_success "OIDC client 'grist-client' создан (ID: $client_id)"
        echo "$client_id"
        return
    fi

    if [[ "$http_code" == "409" ]] || echo "$response" | grep -qi 'exists\|Conflict'; then
        log_info "OIDC client 'grist-client' уже существует (HTTP $http_code)"
        client_id=$(curl -s -X GET \
            "$KEYCLOAK_URL/admin/realms/grist/clients?clientId=grist-client" \
            -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')
        if [[ -n "$client_id" ]]; then
            log_success "Используется существующий OIDC client (ID: $client_id)"
            echo "$client_id"
            return
        fi
    fi

    err_txt=$(echo "$response" | jq -r '.error_description // .errorMessage // .error // empty' 2>/dev/null || true)
    echo "Полный ответ Keycloak (HTTP $http_code): $response" >&2
    if [[ -n "$err_txt" ]]; then
        log_error "Ошибка при создании client: $err_txt"
    fi
    log_error "Не удалось создать client (нет id в ответе)"
}

################################################################################
# Получение Client Secret
################################################################################

get_client_secret() {
    local token="$1"
    local client_id="$2"

    log_info "Получение client secret..."

    local response=$(curl -s -X GET \
        "$KEYCLOAK_URL/admin/realms/grist/clients/$client_id/client-secret" \
        -H "Authorization: Bearer $token")

    local secret=$(echo "$response" | jq -r '.value // empty')

    if [[ -z "$secret" ]]; then
        echo "Ответ: $response" >&2
        log_error "Не удалось получить client secret"
    fi

    log_success "Client secret получен"
    echo "$secret"
}

################################################################################
# Включение User Registration
################################################################################

enable_user_registration() {
    local token="$1"

    log_info "Включение User Registration в realm..."

    curl -s -X PUT \
        "$KEYCLOAK_URL/admin/realms/grist" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{
            "registrationAllowed": true,
            "registrationEmailAsUsername": true
        }' > /dev/null

    log_success "User Registration включена"
}

################################################################################
# Создание тестового пользователя
################################################################################

create_test_user() {
    local token="$1"
    local email="${2:-test@example.com}"
    local password="${3:-TestPassword123!}"

    log_info "Создание тестового пользователя: $email"

    # Проверить существование пользователя
    local user_id=$(curl -s -X GET \
        "$KEYCLOAK_URL/admin/realms/grist/users?email=$email&exact=true" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    if [[ ! -z "$user_id" ]]; then
        log_info "Пользователь $email уже существует"
        return
    fi

    # Создать пользователя
    local response=$(curl -s -i -X POST \
        "$KEYCLOAK_URL/admin/realms/grist/users" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d '{
            "username": "'$email'",
            "email": "'$email'",
            "enabled": true,
            "emailVerified": true,
            "credentials": [
                {
                    "type": "password",
                    "value": "'$password'",
                    "temporary": false
                }
            ]
        }')

    # Извлечь user_id из Location header
    user_id=$(echo "$response" | grep -i "location:" | sed 's/.*\/\([^\/]*\)$/\1/')

    if [[ -z "$user_id" ]]; then
        log_error "Не удалось создать пользователя"
    else
        log_success "Тестовый пользователь создан: $email"
    fi
}

################################################################################
# Основная функция
################################################################################

main() {
    log_info "Keycloak Realm и OIDC Client Setup"
    log_info "Keycloak URL: $KEYCLOAK_URL"

    # Валидация
    if [[ -z "$KEYCLOAK_ADMIN_PASSWORD" ]]; then
        log_error "KEYCLOAK_ADMIN_PASSWORD не установлен"
    fi

    if [[ -z "$GRIST_DOMAIN" || -z "$AUTH_DOMAIN" ]]; then
        log_error "GRIST_DOMAIN и AUTH_DOMAIN должны быть установлены"
    fi

    # Ждём пока Keycloak будет доступен
    log_info "Ожидание Keycloak..."
    for i in {1..60}; do
        if curl -s -f "$KEYCLOAK_URL/realms/master/.well-known/openid-configuration" > /dev/null 2>&1; then
            log_success "Keycloak доступен"
            break
        fi
        if [ $i -eq 60 ]; then
            log_error "Keycloak не стартовал за 5 минут"
        fi
        sleep 5
    done

    # Получить admin token
    local admin_token
    admin_token=$(get_admin_token)

    # Создать realm
    create_realm "$admin_token"

    # Создать OIDC client
    local client_id
    client_id=$(create_oidc_client "$admin_token")

    # Получить client secret
    local client_secret
    client_secret=$(get_client_secret "$admin_token" "$client_id")

    # Включить user registration
    enable_user_registration "$admin_token"

    # Сохранить client secret в файл
    echo "$client_secret" > "$GRIST_OIDC_CLIENT_SECRET_FILE"
    chmod 600 "$GRIST_OIDC_CLIENT_SECRET_FILE"
    log_success "Client secret сохранён в: $GRIST_OIDC_CLIENT_SECRET_FILE"

    log_success "Keycloak setup завершён!"
    echo ""
    echo "GRIST_OIDC_CLIENT_SECRET=$client_secret"
}

main "$@"
