#!/bin/bash

################################################################################
# Grist + Keycloak Deployment Script
# Развертывание Grist + Keycloak + PostgreSQL на Ubuntu 24 VPS
################################################################################

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Переменные по умолчанию
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="/opt/grist-sso"
LOG_FILE="/tmp/grist-keycloak-deploy.log"
CREDENTIALS_FILE=""
OUTPUT_FILE=""
ROLLBACK_MODE=false
KEEP_DATA=true
CLEAR_SSL=false

# Конфиг
AUTH_DOMAIN=""
GRIST_DOMAIN=""
EMAIL_USER=""
EMAIL_PASSWORD=""
EMAIL_HOST="smtp.gmail.com"
EMAIL_PORT="587"
GRIST_ADMIN_EMAIL=""
GRIST_ORG="ssa"
CERTBOT_EMAIL=""
KEYCLOAK_VERSION="24.0"
GRIST_VERSION="latest"
POSTGRES_VERSION="15-alpine"

################################################################################
# Функции логирования
################################################################################

log_info() {
    echo -e "${BLUE}ℹ${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}✅${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}❌${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC}  $1" | tee -a "$LOG_FILE"
}

log_step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}" | tee -a "$LOG_FILE"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

################################################################################
# Проверка requirements
################################################################################

check_requirements() {
    log_step "Проверка требований"

    # Проверить ОС
    if ! grep -qi "Ubuntu" /etc/os-release; then
        log_error "Скрипт работает только на Ubuntu"
        exit 1
    fi

    # Проверить root
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен запускаться с правами root (sudo)"
        exit 1
    fi

    # Проверить утилиты
    for cmd in docker curl openssl git; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd не установлен"
            log_info "Установите: apt-get install -y $cmd"
            exit 1
        fi
    done

    # Проверить docker-compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "docker-compose не установлен"
        exit 1
    fi

    log_success "Все требования выполнены"
}

################################################################################
# Обработка аргументов
################################################################################

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auth-domain)
                AUTH_DOMAIN="$2"
                shift 2
                ;;
            --grist-domain)
                GRIST_DOMAIN="$2"
                shift 2
                ;;
            --email-user)
                EMAIL_USER="$2"
                shift 2
                ;;
            --email-password)
                EMAIL_PASSWORD="$2"
                shift 2
                ;;
            --email-host)
                EMAIL_HOST="$2"
                shift 2
                ;;
            --grist-admin-email)
                GRIST_ADMIN_EMAIL="$2"
                shift 2
                ;;
            --certbot-email)
                CERTBOT_EMAIL="$2"
                shift 2
                ;;
            --rollback)
                ROLLBACK_MODE=true
                shift
                ;;
            --keep-data)
                KEEP_DATA=true
                shift
                ;;
            --delete-all)
                KEEP_DATA=false
                shift
                ;;
            --clear-ssl)
                CLEAR_SSL=true
                shift
                ;;
            *)
                log_error "Неизвестный параметр: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

print_usage() {
    cat << EOF
Использование: sudo ./deploy.sh [OPTIONS]

Развертывание:
  ./deploy.sh                                    # Интерактивный режим
  ./deploy.sh --auth-domain auth.example.com \
              --grist-domain grist.example.com \
              --email-user admin@gmail.com \
              --email-password "app-password"

Откатывание:
  ./deploy.sh --rollback --keep-data             # Откатить, сохранить БД
  ./deploy.sh --rollback --delete-all            # Полная очистка (опасно!)

Параметры:
  --auth-domain DOMAIN            Домен для Keycloak (обязательный)
  --grist-domain DOMAIN           Домен для Grist (обязательный)
  --email-user EMAIL              Email для SMTP (обязательный)
  --email-password PASS           Пароль/App Password (обязательный)
  --email-host HOST               SMTP хост (по умолчанию: smtp.gmail.com)
  --grist-admin-email EMAIL       Email админа Grist (обязательный)
  --certbot-email EMAIL           Email для Let's Encrypt (обязательный)
  --keep-data                     При откатывании сохранить БД (по умолчанию)
  --delete-all                    При откатывании удалить всё (опасно!)
  --clear-ssl                     Удалить SSL сертификаты

EOF
}

################################################################################
# Интерактивный ввод
################################################################################

interactive_input() {
    log_step "Интерактивная настройка"

    if [[ -z "$AUTH_DOMAIN" ]]; then
        read -p "📝 Домен для Keycloak (например: auth.example.com): " AUTH_DOMAIN
        if [[ -z "$AUTH_DOMAIN" ]]; then
            log_error "Домен не может быть пустым"
            exit 1
        fi
    fi

    if [[ -z "$GRIST_DOMAIN" ]]; then
        read -p "📝 Домен для Grist (например: grist.example.com): " GRIST_DOMAIN
        if [[ -z "$GRIST_DOMAIN" ]]; then
            log_error "Домен не может быть пустым"
            exit 1
        fi
    fi

    if [[ -z "$EMAIL_USER" ]]; then
        read -p "📝 Email для SMTP (например: noreply@gmail.com): " EMAIL_USER
        if [[ -z "$EMAIL_USER" ]]; then
            log_error "Email не может быть пустым"
            exit 1
        fi
    fi

    if [[ -z "$EMAIL_PASSWORD" ]]; then
        read -sp "🔐 Пароль/App Password для SMTP: " EMAIL_PASSWORD
        echo ""
        if [[ -z "$EMAIL_PASSWORD" ]]; then
            log_error "Пароль не может быть пустым"
            exit 1
        fi
    fi

    if [[ -z "$GRIST_ADMIN_EMAIL" ]]; then
        read -p "📝 Email администратора Grist: " GRIST_ADMIN_EMAIL
        if [[ -z "$GRIST_ADMIN_EMAIL" ]]; then
            log_error "Email админа не может быть пустым"
            exit 1
        fi
    fi

    if [[ -z "$CERTBOT_EMAIL" ]]; then
        read -p "📝 Email для Let's Encrypt (для уведомлений об истечении): " CERTBOT_EMAIL
        if [[ -z "$CERTBOT_EMAIL" ]]; then
            log_error "Email certbot не может быть пустым"
            exit 1
        fi
    fi

    log_success "Конфигурация введена"
}

################################################################################
# Валидация входных данных
################################################################################

validate_input() {
    log_step "Валидация конфигурации"

    # Проверить что домены не пусты
    if [[ -z "$AUTH_DOMAIN" || -z "$GRIST_DOMAIN" || -z "$EMAIL_USER" || -z "$EMAIL_PASSWORD" || -z "$GRIST_ADMIN_EMAIL" || -z "$CERTBOT_EMAIL" ]]; then
        log_error "Не все параметры заполнены"
        exit 1
    fi

    # Проверить что домены не одинаковые
    if [[ "$AUTH_DOMAIN" == "$GRIST_DOMAIN" ]]; then
        log_error "AUTH_DOMAIN и GRIST_DOMAIN должны быть разными"
        exit 1
    fi

    # Базовая проверка email
    if ! [[ "$GRIST_ADMIN_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Неверный формат email: $GRIST_ADMIN_EMAIL"
        exit 1
    fi

    log_success "Валидация пройдена"
}

################################################################################
# Генерация паролей и конфигурации
################################################################################

generate_secrets() {
    log_step "Генерация секретов и паролей"

    KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -base64 32)
    POSTGRES_KEYCLOAK_PASSWORD=$(openssl rand -base64 32)
    GRIST_OIDC_CLIENT_SECRET=$(openssl rand -base64 32)
    GRIST_API_KEY=$(openssl rand -hex 40)

    log_success "Секреты сгенерированы"
}

################################################################################
# Создание директорий
################################################################################

setup_directories() {
    log_step "Подготовка директорий"

    if [[ ! -d "$DEPLOY_DIR" ]]; then
        mkdir -p "$DEPLOY_DIR"
        log_info "Создана директория: $DEPLOY_DIR"
    fi

    CREDENTIALS_FILE="$DEPLOY_DIR/deploy-credentials.txt"
    OUTPUT_FILE="$DEPLOY_DIR/deploy-output.txt"

    cd "$DEPLOY_DIR"
    log_success "Рабочая директория: $DEPLOY_DIR"
}

################################################################################
# Генерация .env файла
################################################################################

create_env_file() {
    log_step "Создание .env файла"

    local ENV_FILE="$DEPLOY_DIR/.env"

    cat > "$ENV_FILE" << EOF
# Grist + Keycloak Configuration
# Сгенерировано: $(date)

# Домены
AUTH_DOMAIN=$AUTH_DOMAIN
GRIST_DOMAIN=$GRIST_DOMAIN

# Keycloak
KEYCLOAK_REALM=grist
KEYCLOAK_ADMIN_PASSWORD=$KEYCLOAK_ADMIN_PASSWORD

# PostgreSQL
POSTGRES_KEYCLOAK_PASSWORD=$POSTGRES_KEYCLOAK_PASSWORD

# OIDC Client
GRIST_OIDC_CLIENT_ID=grist-client
GRIST_OIDC_CLIENT_SECRET=$GRIST_OIDC_CLIENT_SECRET

# Grist
GRIST_ORG=$GRIST_ORG
GRIST_INITIAL_ADMIN_EMAIL=$GRIST_ADMIN_EMAIL
GRIST_API_KEY=$GRIST_API_KEY

# Email/SMTP
EMAIL_HOST=$EMAIL_HOST
EMAIL_PORT=$EMAIL_PORT
EMAIL_USER=$EMAIL_USER
EMAIL_PASSWORD=$EMAIL_PASSWORD
EMAIL_FROM_ADDRESS=$EMAIL_USER

# Версии образов
KEYCLOAK_VERSION=$KEYCLOAK_VERSION
GRIST_VERSION=$GRIST_VERSION
POSTGRES_VERSION=$POSTGRES_VERSION
EOF

    chmod 600 "$ENV_FILE"
    log_success ".env файл создан: $ENV_FILE"
}

################################################################################
# Генерация docker-compose.yml
################################################################################

create_docker_compose() {
    log_step "Генерация docker-compose.yml"

    local COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"

    # Копируем из template или создаём встроенный
    cat > "$COMPOSE_FILE" << 'EOF'
networks:
  grist-sso-net:
    driver: bridge

volumes:
  keycloak-db-data:
  grist-data:

services:
  postgres-keycloak:
    image: postgres:${POSTGRES_VERSION}
    container_name: grist-sso-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${POSTGRES_KEYCLOAK_PASSWORD}
    volumes:
      - keycloak-db-data:/var/lib/postgresql/data
    networks:
      - grist-sso-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak"]
      interval: 10s
      timeout: 5s
      retries: 5

  keycloak:
    image: quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}
    container_name: grist-sso-keycloak
    restart: unless-stopped
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres-keycloak:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${POSTGRES_KEYCLOAK_PASSWORD}
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: ${KEYCLOAK_ADMIN_PASSWORD}
      KC_HOSTNAME: ${AUTH_DOMAIN}
      KC_PROXY: edge
      KC_HTTP_ENABLED: "true"
      KC_HOSTNAME_STRICT: "false"
      JAVA_OPTS_APPEND: "-Xms256m -Xmx512m -XX:MetaspaceSize=96M -XX:MaxMetaspaceSize=256m"
    command: start
    ports:
      - "127.0.0.1:8090:8080"
    networks:
      - grist-sso-net
    depends_on:
      postgres-keycloak:
        condition: service_healthy

  grist:
    image: gristlabs/grist:${GRIST_VERSION}
    container_name: grist-sso-grist
    restart: unless-stopped
    environment:
      APP_HOME_URL: https://${GRIST_DOMAIN}
      GRIST_OIDC_SP_HOST: https://${GRIST_DOMAIN}
      GRIST_OIDC_IDP_ISSUER: http://grist-sso-keycloak:8080/realms/${KEYCLOAK_REALM}
      GRIST_OIDC_IDP_SCOPES: openid profile email
      GRIST_OIDC_IDP_CLIENT_ID: ${GRIST_OIDC_CLIENT_ID}
      GRIST_OIDC_IDP_CLIENT_SECRET: ${GRIST_OIDC_CLIENT_SECRET}
      GRIST_FORCE_LOGIN: "true"
      GRIST_ANON_PLAYGROUND: "false"
      GRIST_SINGLE_ORG: ${GRIST_ORG}
      GRIST_OIDC_SP_IGNORE_EMAIL_VERIFIED: "false"
    volumes:
      - grist-data:/persist
    ports:
      - "127.0.0.1:3000:8484"
    networks:
      - grist-sso-net
    depends_on:
      - keycloak
EOF

    log_success "docker-compose.yml создан"
}

################################################################################
# Запуск контейнеров
################################################################################

start_containers() {
    log_step "Запуск контейнеров Docker"

    cd "$DEPLOY_DIR"

    log_info "Запуск PostgreSQL и Keycloak..."
    docker-compose up -d postgres-keycloak keycloak

    log_info "Ожидание Keycloak (максимум 5 минут)..."
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker-compose logs keycloak 2>/dev/null | grep -q "Running the server"; then
            log_success "Keycloak готов"
            break
        fi

        attempt=$((attempt + 1))
        echo -ne "\r⏳ Попытка $attempt/$max_attempts..."
        sleep 5
    done

    if [ $attempt -eq $max_attempts ]; then
        log_warning "Keycloak не стартовал за 5 минут"
        log_info "Проверьте логи: docker-compose logs keycloak"
        read -p "Продолжить ожидание? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Развертывание отменено"
            exit 1
        fi
    fi

    log_info "Запуск Grist..."
    docker-compose up -d grist

    log_success "Все контейнеры запущены"
}

################################################################################
# Основной flow
################################################################################

main() {
    # Инициализация логирования
    > "$LOG_FILE"

    log_step "Grist + Keycloak Deployment Script"
    log_info "Дата: $(date)"

    # Обработка аргументов
    parse_arguments "$@"

    # Проверка requirements
    check_requirements

    # Откатывание
    if [[ "$ROLLBACK_MODE" == true ]]; then
        rollback_deployment
        exit 0
    fi

    # Интерактивный ввод или валидация флагов
    interactive_input
    validate_input

    # Генерация и создание конфиг файлов
    generate_secrets
    setup_directories
    create_env_file
    create_docker_compose

    # Запуск контейнеров
    start_containers

    # TODO: Создание Keycloak realm и клиента
    # TODO: Тесты развертывания
    # TODO: Вывод credentials и QR кода

    log_step "Развертывание завершено!"
    log_info "Следующие шаги: см. $OUTPUT_FILE"
}

################################################################################
# Откатывание
################################################################################

rollback_deployment() {
    log_step "Откатывание развертывания"

    cd "$DEPLOY_DIR" 2>/dev/null || return 1

    # Остановка контейнеров
    log_info "Остановка контейнеров..."
    docker-compose stop 2>/dev/null || true
    docker-compose rm -f 2>/dev/null || true

    # Удаление Nginx конфигов
    log_info "Удаление Nginx конфигов..."
    rm -f /etc/nginx/sites-enabled/*bytepace.com.conf 2>/dev/null || true
    rm -f /etc/nginx/sites-available/*bytepace.com.conf 2>/dev/null || true
    systemctl reload nginx 2>/dev/null || true

    # Удаление SSL сертификатов если нужно
    if [[ "$CLEAR_SSL" == true ]]; then
        log_warning "Удаление SSL сертификатов..."
        rm -rf /etc/letsencrypt/live/*bytepace.com 2>/dev/null || true
    fi

    # Удаление volumes если указано
    if [[ "$KEEP_DATA" == false ]]; then
        log_warning "Удаление всех данных БД и файлов Grist..."
        docker volume rm grist-sso_keycloak-db-data grist-sso_grist-data 2>/dev/null || true
        log_warning "⚠️  НЕВОЗМОЖНО ВОССТАНОВИТЬ"
    else
        log_info "БД и данные Grist сохранены"
    fi

    log_success "Откатывание завершено"
}

# Запуск
main "$@"
