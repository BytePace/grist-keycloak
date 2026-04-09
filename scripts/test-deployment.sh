#!/bin/bash

################################################################################
# Deployment Testing Script
# Проверка что всё работает корректно
################################################################################

set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Параметры
AUTH_DOMAIN="${AUTH_DOMAIN}"
GRIST_DOMAIN="${GRIST_DOMAIN}"
DEPLOY_DIR="${DEPLOY_DIR:-.}"

# Результаты
TESTS_PASSED=0
TESTS_FAILED=0

################################################################################
# Функции логирования
################################################################################

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_error() {
    echo -e "${RED}❌${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_warning() {
    echo -e "${YELLOW}⚠${NC}  $1"
}

log_test() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

################################################################################
# Тест: DNS разрешение
################################################################################

test_dns() {
    log_test "Тест DNS разрешения"

    for domain in "$AUTH_DOMAIN" "$GRIST_DOMAIN"; do
        log_info "Проверка: $domain"
        if nslookup "$domain" > /dev/null 2>&1; then
            log_success "$domain разрешается"
        else
            log_error "$domain не разрешается (проверьте DNS)"
        fi
    done
}

################################################################################
# Тест: Ports открыты
################################################################################

test_ports() {
    log_test "Тест открытых портов"

    local ports=(80 443 22)
    for port in "${ports[@]}"; do
        log_info "Проверка порт $port..."
        if nc -z localhost "$port" > /dev/null 2>&1; then
            log_success "Порт $port открыт"
        else
            log_error "Порт $port закрыт"
        fi
    done
}

################################################################################
# Тест: Docker контейнеры запущены
################################################################################

test_docker_containers() {
    log_test "Проверка Docker контейнеров"

    local containers=("grist-sso-postgres" "grist-sso-keycloak" "grist-sso-grist")

    for container in "${containers[@]}"; do
        if docker ps --filter "name=$container" --format "{{.Names}}" | grep -q "$container"; then
            log_success "Контейнер '$container' запущен"
        else
            log_error "Контейнер '$container' не запущен"
        fi
    done
}

################################################################################
# Тест: Keycloak доступен по HTTPS
################################################################################

test_keycloak_https() {
    log_test "Проверка Keycloak по HTTPS"

    log_info "Проверка: https://$AUTH_DOMAIN"

    local http_code=$(curl -s -o /dev/null -w "%{http_code}" -k "https://$AUTH_DOMAIN" || echo "000")

    if [[ "$http_code" == "200" || "$http_code" == "302" || "$http_code" == "301" ]]; then
        log_success "Keycloak доступен (HTTP $http_code)"
    else
        log_error "Keycloak не доступен (HTTP $http_code)"
    fi
}

################################################################################
# Тест: Grist доступен по HTTPS
################################################################################

test_grist_https() {
    log_test "Проверка Grist по HTTPS"

    log_info "Проверка: https://$GRIST_DOMAIN"

    local http_code=$(curl -s -o /dev/null -w "%{http_code}" -k "https://$GRIST_DOMAIN" || echo "000")

    if [[ "$http_code" == "200" || "$http_code" == "302" || "$http_code" == "301" ]]; then
        log_success "Grist доступен (HTTP $http_code)"
    else
        log_error "Grist не доступен (HTTP $http_code)"
    fi
}

################################################################################
# Тест: OIDC Discovery Endpoint
################################################################################

test_oidc_discovery() {
    log_test "Проверка OIDC Discovery Endpoint"

    local endpoint="https://$AUTH_DOMAIN/realms/grist/.well-known/openid-configuration"
    log_info "Проверка: $endpoint"

    if curl -s -k "$endpoint" | jq -e '.issuer' > /dev/null 2>&1; then
        log_success "OIDC Discovery работает"

        # Проверить основные поля
        local issuer=$(curl -s -k "$endpoint" | jq -r '.issuer')
        log_info "Issuer: $issuer"
    else
        log_error "OIDC Discovery не работает"
    fi
}

################################################################################
# Тест: SSL сертификаты валидны
################################################################################

test_ssl_certificates() {
    log_test "Проверка SSL сертификатов"

    for domain in "$AUTH_DOMAIN" "$GRIST_DOMAIN"; do
        log_info "Проверка сертификата для: $domain"

        local expiry=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | \
                       openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

        if [[ ! -z "$expiry" ]]; then
            log_success "Сертификат для $domain действует до: $expiry"
        else
            log_error "Не удалось проверить сертификат для $domain"
        fi
    done
}

################################################################################
# Тест: PostgreSQL доступна
################################################################################

test_postgres() {
    log_test "Проверка PostgreSQL"

    if docker exec grist-sso-postgres pg_isready -U keycloak > /dev/null 2>&1; then
        log_success "PostgreSQL доступна"
    else
        log_error "PostgreSQL не доступна"
    fi
}

################################################################################
# Тест: Email конфигурация
################################################################################

test_email_config() {
    log_test "Проверка Email конфигурации"

    log_info "Проверка SMTP configuration в Keycloak..."

    # Получить realm config из Keycloak
    local realm_config=$(curl -s -k "https://$AUTH_DOMAIN/admin/realms/grist" \
        -H "Accept: application/json" 2>/dev/null || echo "{}")

    if echo "$realm_config" | jq -e '.smtpServer' > /dev/null 2>&1; then
        log_success "SMTP конфигурация установлена"
    else
        log_warning "SMTP конфигурация может быть не установлена (проверьте вручную)"
    fi
}

################################################################################
# Тест: OIDC Login Flow (check if redirect works)
################################################################################

test_oidc_login_flow() {
    log_test "Проверка OIDC Login Flow"

    log_info "Проверка редиректа с Grist на Keycloak..."

    local redirect=$(curl -s -k -o /dev/null -w "%{redirect_url}" "https://$GRIST_DOMAIN" || echo "")

    if echo "$redirect" | grep -q "keycloak\|oidc\|openid"; then
        log_success "OIDC редирект работает"
        log_info "Редирект URL: $redirect"
    else
        log_warning "OIDC редирект может быть не настроен (проверьте вручную)"
    fi
}

################################################################################
# Вывод результатов
################################################################################

print_summary() {
    log_test "Результаты тестирования"

    local total=$((TESTS_PASSED + TESTS_FAILED))
    local percent=0
    if [ $total -gt 0 ]; then
        percent=$((TESTS_PASSED * 100 / total))
    fi

    echo -e "${GREEN}Пройдено: $TESTS_PASSED${NC}"
    echo -e "${RED}Не пройдено: $TESTS_FAILED${NC}"
    echo -e "Успешность: ${BLUE}${percent}%${NC}"

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "\n${GREEN}✅ Все тесты пройдены успешно!${NC}"
        return 0
    fi

    echo -e "\n${YELLOW}⚠️  Некоторые тесты не пройдены (часто из‑за nginx/HTTPS — см. deploy.sh и документацию).${NC}"
    return 1
}

################################################################################
# Основная функция
################################################################################

main() {
    log_info "Deployment Testing"
    log_info "Auth Domain: $AUTH_DOMAIN"
    log_info "Grist Domain: $GRIST_DOMAIN"

    # Валидация параметров
    if [[ -z "$AUTH_DOMAIN" || -z "$GRIST_DOMAIN" ]]; then
        log_error "AUTH_DOMAIN и GRIST_DOMAIN должны быть установлены"
    fi

    # Запустить тесты
    test_dns
    test_docker_containers
    test_keycloak_https
    test_grist_https
    test_oidc_discovery
    test_ssl_certificates
    test_postgres
    test_email_config
    test_oidc_login_flow

    # Вывести результаты
    echo ""
    print_summary
}

main "$@"
