#!/bin/bash

################################################################################
# Keycloak Realm и OIDC Client Setup
# Создание realm "grist", confidential client "grist-client" (Grist web) и
# public client для нативных приложений (PKCE), по умолчанию "grist-mobile".
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
# Нативные приложения (iOS/Android): public client + PKCE, без client_secret
GRIST_MOBILE_OIDC_CLIENT_ID="${GRIST_MOBILE_OIDC_CLIENT_ID:-grist-mobile}"
GRIST_MOBILE_OIDC_REDIRECT_URI="${GRIST_MOBILE_OIDC_REDIRECT_URI:-com.bytepace.scan-it-to-google-sheets://oauth/callback}"

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

    # После свежего старта Keycloak может логировать "started", но bootstrap-admin
    # ещё не готов — token endpoint временно отвечает invalid_grant.
    local max_attempts=30
    local attempt=0
    local response token err

    while [[ $attempt -lt $max_attempts ]]; do
        response=$(curl -s -X POST \
            "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" \
            -d "username=$KEYCLOAK_ADMIN" \
            -d "password=$KEYCLOAK_ADMIN_PASSWORD")

        token=$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null || true)
        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi

        err=$(echo "$response" | jq -r '.error_description // .error // empty' 2>/dev/null || true)
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_attempts ]]; then
            log_warning "Token ещё не получен (попытка $attempt/$max_attempts): ${err:-unknown error}. Повтор через 2s..."
            sleep 2
            continue
        fi
    done

    echo "Ответ Keycloak: $response" >&2
    log_error "Не удалось получить admin token"
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
        }
        | .verifyEmail = true
        | .resetPasswordAllowed = true
        | .rememberMe = true') || {
        log_warning "Не удалось собрать JSON SMTP (jq). Настройте SMTP вручную в админке Keycloak."
        return 0
    }

    put_tmp=$(mktemp)
    http_code=$(curl -sS -o "$put_tmp" -w "%{http_code}" -X PUT \
        "$KEYCLOAK_URL/admin/realms/grist" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "$merged")
    put_body=$(cat "$put_tmp")
    rm -f "$put_tmp"

    if [[ "$http_code" == "204" ]] || [[ "$http_code" == "200" ]]; then
        log_success "SMTP для realm 'grist' настроен; Verify email включён (verifyEmail=true)"
    else
        log_warning "SMTP не применён (HTTP $http_code). Настройте вручную: Realm grist → Realm settings → Email. Ответ: $put_body"
    fi
}

create_realm() {
    local token="$1"

    log_info "Создание realm 'grist' (без SMTP в POST — он добавляется отдельно)..."

    # Тело только через jq + --data-binary: многострочный -d в bash иногда даёт Keycloak 400
    # "unable to read contents from stream". refreshTokenLifespan не входит в RealmRepresentation —
    # для SSO idle используем ssoSessionIdleTimeout.
    local payload_file tmp http_code response err_txt verify
    payload_file=$(mktemp)
    jq -n '{
        realm: "grist",
        enabled: true,
        displayName: "Grist",
        loginTheme: "keycloak",
        emailTheme: "keycloak",
        verifyEmail: true,
        resetPasswordAllowed: true,
        rememberMe: true,
        accessTokenLifespan: 3600,
        ssoSessionIdleTimeout: 604800,
        offlineSessionIdleTimeout: 2592000
    }' > "$payload_file"

    tmp=$(mktemp)
    http_code=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST \
        "$KEYCLOAK_URL/admin/realms" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json; charset=UTF-8" \
        --data-binary @"$payload_file")
    rm -f "$payload_file"
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

    # ClientRepresentation: publicClient + protocol. При 201 Keycloak часто отдаёт пустое тело,
    # UUID клиента — в заголовке Location: .../clients/<id>
    local hdr tmp http_code response client_id err_txt location
    hdr=$(mktemp)
    tmp=$(mktemp)
    http_code=$(curl -sS -D "$hdr" -o "$tmp" -w "%{http_code}" -X POST \
        "$KEYCLOAK_URL/admin/realms/grist/clients" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json; charset=UTF-8" \
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
            "baseUrl": "https://'$GRIST_DOMAIN'",
            "attributes": {
                "post.logout.redirect.uris": "https://'$GRIST_DOMAIN'/signed-out"
            }
        }')
    response=$(cat "$tmp")
    rm -f "$tmp"
    location=$(grep -i '^[Ll]ocation:' "$hdr" | head -1 | tr -d '\r' | sed 's/^[Ll]ocation:[[:space:]]*//')
    rm -f "$hdr"

    client_id=$(echo "$response" | jq -r '.id // empty')
    if [[ -z "$client_id" ]] && [[ -n "$location" ]]; then
        client_id="${location##*/}"
        client_id="${client_id%%\?*}"
    fi
    if [[ -z "$client_id" ]] && [[ "$http_code" == "201" ]]; then
        client_id=$(curl -s -X GET \
            "$KEYCLOAK_URL/admin/realms/grist/clients?clientId=grist-client" \
            -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')
    fi

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
# Public OIDC client для нативных приложений (PKCE S256)
# Отдельно от grist-client: тот confidential и с секретом для сервера Grist.
################################################################################

create_or_update_oidc_mobile_client() {
    local token="$1"
    local client_id_name="$GRIST_MOBILE_OIDC_CLIENT_ID"
    local redirect_uri="$GRIST_MOBILE_OIDC_REDIRECT_URI"

    log_info "OIDC client '$client_id_name' (public + PKCE) для нативных приложений; redirect: $redirect_uri"

    local internal_uuid
    internal_uuid=$(curl -s -G \
        "$KEYCLOAK_URL/admin/realms/grist/clients" \
        --data-urlencode "clientId=$client_id_name" \
        -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')

    local payload_file tmp http_code response err_txt hdr location
    payload_file=$(mktemp)
    jq -n \
        --arg cid "$client_id_name" \
        --arg uri "$redirect_uri" \
        '{
            clientId: $cid,
            protocol: "openid-connect",
            enabled: true,
            publicClient: true,
            bearerOnly: false,
            standardFlowEnabled: true,
            directAccessGrantsEnabled: false,
            implicitFlowEnabled: false,
            serviceAccountsEnabled: false,
            authorizationServicesEnabled: false,
            redirectUris: [$uri],
            webOrigins: ["+"],
            attributes: {
                "pkce.code.challenge.method": "S256"
            }
        }' > "$payload_file"

    if [[ -z "$internal_uuid" ]]; then
        hdr=$(mktemp)
        tmp=$(mktemp)
        http_code=$(curl -sS -D "$hdr" -o "$tmp" -w "%{http_code}" -X POST \
            "$KEYCLOAK_URL/admin/realms/grist/clients" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json; charset=UTF-8" \
            --data-binary @"$payload_file")
        response=$(cat "$tmp")
        rm -f "$tmp"
        location=$(grep -i '^[Ll]ocation:' "$hdr" | head -1 | tr -d '\r' | sed 's/^[Ll]ocation:[[:space:]]*//')
        rm -f "$hdr"

        internal_uuid=$(echo "$response" | jq -r '.id // empty')
        if [[ -z "$internal_uuid" && -n "$location" ]]; then
            internal_uuid="${location##*/}"
            internal_uuid="${internal_uuid%%\?*}"
        fi
        if [[ -z "$internal_uuid" && "$http_code" == "201" ]]; then
            internal_uuid=$(curl -s -G \
                "$KEYCLOAK_URL/admin/realms/grist/clients" \
                --data-urlencode "clientId=$client_id_name" \
                -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')
        fi

        rm -f "$payload_file"

        if [[ "$http_code" == "201" ]] && [[ -n "$internal_uuid" ]]; then
            log_success "OIDC client '$client_id_name' создан (UUID: $internal_uuid)"
            return 0
        fi
        if [[ "$http_code" == "409" ]] || echo "$response" | grep -qi 'exists\|Conflict'; then
            log_info "Клиент '$client_id_name' уже существует (HTTP $http_code), синхронизация настроек..."
            internal_uuid=$(curl -s -G \
                "$KEYCLOAK_URL/admin/realms/grist/clients" \
                --data-urlencode "clientId=$client_id_name" \
                -H "Authorization: Bearer $token" | jq -r '.[0].id // empty')
        else
            err_txt=$(echo "$response" | jq -r '.error_description // .errorMessage // .error // empty' 2>/dev/null || true)
            echo "Ответ Keycloak (HTTP $http_code): $response" >&2
            log_error "Не удалось создать '$client_id_name': ${err_txt:-HTTP $http_code}"
        fi
    else
        rm -f "$payload_file"
        log_info "Клиент '$client_id_name' найден (UUID: $internal_uuid), проверка redirect URI и PKCE..."
    fi

    if [[ -z "$internal_uuid" ]]; then
        log_error "Не удалось определить UUID клиента '$client_id_name' в Keycloak"
    fi

    local current merged put_tmp put_http
    current=$(curl -sS -X GET \
        "$KEYCLOAK_URL/admin/realms/grist/clients/$internal_uuid" \
        -H "Authorization: Bearer $token")

    put_tmp=$(mktemp)
    echo "$current" | jq --arg uri "$redirect_uri" '
        .publicClient = true |
        .standardFlowEnabled = true |
        .directAccessGrantsEnabled = false |
        .implicitFlowEnabled = false |
        .serviceAccountsEnabled = false |
        .authorizationServicesEnabled = false |
        (.redirectUris // []) as $r |
        .redirectUris = ($r + [$uri] | unique) |
        .webOrigins = (if (.webOrigins // []) | length > 0 then .webOrigins else ["+"] end) |
        .attributes = (.attributes // {}) |
        .attributes["pkce.code.challenge.method"] = "S256"
    ' > "$put_tmp"

    put_http=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
        "$KEYCLOAK_URL/admin/realms/grist/clients/$internal_uuid" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d @"$put_tmp")
    rm -f "$put_tmp"

    if [[ "$put_http" == "204" ]] || [[ "$put_http" == "200" ]]; then
        log_success "Клиент '$client_id_name' обновлён (HTTP $put_http): public, PKCE S256, redirect в списке"
    else
        log_warning "PUT '$client_id_name' вернул HTTP $put_http — проверьте клиент в Keycloak Admin Console"
    fi
}

################################################################################
# Post-logout redirect (Grist → Keycloak logout с post_logout_redirect_uri)
################################################################################

# Keycloak 18+ не принимает post_logout_redirect_uri, если URL не в post.logout.redirect.uris
# (ошибка «Invalid redirect uri» на /protocol/openid-connect/logout).
ensure_oidc_client_post_logout_redirect() {
    local token="$1"
    local client_id="$2"

    if [[ -z "$client_id" || -z "$GRIST_DOMAIN" ]]; then
        return 0
    fi

    local post_logout_uri="https://${GRIST_DOMAIN}/signed-out"
    log_info "Проверка post.logout.redirect.uris для grist-client → $post_logout_uri"

    local current tmp merged http_code
    current=$(curl -sS -X GET \
        "$KEYCLOAK_URL/admin/realms/grist/clients/$client_id" \
        -H "Authorization: Bearer $token")

    tmp=$(mktemp)
    echo "$current" | jq --arg u "$post_logout_uri" '
        .attributes = (.attributes // {}) |
        .attributes["post.logout.redirect.uris"] = (
            if ((.attributes["post.logout.redirect.uris"] // "") | index($u)) != null then
                .attributes["post.logout.redirect.uris"]
            elif (.attributes["post.logout.redirect.uris"] // "") == "" then
                $u
            else
                .attributes["post.logout.redirect.uris"] + "##" + $u
            end
        )
    ' > "$tmp"

    http_code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT \
        "$KEYCLOAK_URL/admin/realms/grist/clients/$client_id" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d @"$tmp")
    rm -f "$tmp"

    if [[ "$http_code" == "204" ]] || [[ "$http_code" == "200" ]]; then
        log_success "post.logout.redirect.uris обновлён (HTTP $http_code)"
    else
        log_info "PUT client для post-logout вернул HTTP $http_code (проверьте клиент вручную в Admin Console)"
    fi
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

    log_info "Включение User Registration в realm (без сброса verifyEmail)..."

    local realm_json merged put_tmp http_code put_body
    realm_json=$(curl -s -H "Authorization: Bearer $token" "$KEYCLOAK_URL/admin/realms/grist")
    if [[ -z "$realm_json" ]] || ! echo "$realm_json" | jq -e . >/dev/null 2>&1; then
        log_warning "Не удалось прочитать realm для registration (пропуск merge)"
        curl -s -X PUT \
            "$KEYCLOAK_URL/admin/realms/grist" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            -d '{
                "registrationAllowed": true,
                "registrationEmailAsUsername": true
            }' > /dev/null
        log_success "User Registration включена (частичный PUT)"
        return 0
    fi

    merged=$(echo "$realm_json" | jq \
        '.registrationAllowed = true
         | .registrationEmailAsUsername = true
         | .verifyEmail = true
         | .resetPasswordAllowed = true
         | .rememberMe = true') || {
        log_warning "Не удалось собрать JSON registration (jq)"
        return 0
    }

    put_tmp=$(mktemp)
    http_code=$(curl -sS -o "$put_tmp" -w "%{http_code}" -X PUT \
        "$KEYCLOAK_URL/admin/realms/grist" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json; charset=UTF-8" \
        -d "$merged")
    put_body=$(cat "$put_tmp")
    rm -f "$put_tmp"

    if [[ "$http_code" == "204" ]] || [[ "$http_code" == "200" ]]; then
        log_success "User Registration включена; Verify email остаётся включённым"
    else
        log_warning "PUT realm после registration: HTTP $http_code — проверьте вручную. Ответ: $put_body"
    fi
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

    ensure_oidc_client_post_logout_redirect "$admin_token" "$client_id"

    # Публичный клиент для iOS/Android (PKCE), отдельно от grist-client
    create_or_update_oidc_mobile_client "$admin_token"

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
