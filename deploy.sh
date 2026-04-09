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
VERBOSE=false
RESET_POSTGRES_VOLUME=false
SETUP_NGINX=false

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

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" | tee -a "$LOG_FILE"
    fi
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
    for cmd in docker curl openssl git jq; do
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
            --verbose)
                VERBOSE=true
                shift
                ;;
            --reset-postgres-volume)
                RESET_POSTGRES_VOLUME=true
                shift
                ;;
            --setup-nginx)
                SETUP_NGINX=true
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
  --verbose                       Verbose логирование (отладка)
  --reset-postgres-volume         Удалить Docker-том БД Keycloak перед деплоем (после
                                  смены пароля в .env без совпадения с данными в томе;
                                  данные realm в Postgres будут потеряны)
  --setup-nginx                   После деплоя установить конфиг nginx (нужны
                                  сертификаты certbot для AUTH_DOMAIN и GRIST_DOMAIN)

Примеры:
  # С verbose режимом для отладки
  sudo ./deploy.sh --auth-domain auth.example.com ... --verbose

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

# Прочитать значение из .env (одна строка KEY=value..., значение может содержать '=')
read_env_var() {
    local key="$1"
    local file="$2"
    local line
    line=$(grep "^${key}=" "$file" 2>/dev/null | head -1) || true
    if [[ -n "$line" ]]; then
        echo "${line#"${key}="}"
    fi
}

generate_secrets() {
    log_step "Генерация секретов и паролей"

    local ENV_FILE="$DEPLOY_DIR/.env"
    local existing_pg_volume=false
    if docker volume ls -q 2>/dev/null | grep -q 'keycloak-db-data'; then
        existing_pg_volume=true
    fi

    # PostgreSQL хранит пароль только при первом init тома; при повторном запуске скрипта
    # нельзя генерировать новый POSTGRES_KEYCLOAK_PASSWORD, если данные БД уже есть.
    if [[ -f "$ENV_FILE" ]] && [[ "$KEEP_DATA" == true ]]; then
        log_info "Загрузка секретов из $ENV_FILE (без перегенерации при KEEP_DATA)"
        log_info "Если Keycloak пишет «password authentication failed», пароль в .env не совпадает с тем, что был при первом init тома PostgreSQL — удалите том или запустите с --reset-postgres-volume"
        KEYCLOAK_ADMIN_PASSWORD=$(read_env_var KEYCLOAK_ADMIN_PASSWORD "$ENV_FILE")
        POSTGRES_KEYCLOAK_PASSWORD=$(read_env_var POSTGRES_KEYCLOAK_PASSWORD "$ENV_FILE")
        GRIST_OIDC_CLIENT_SECRET=$(read_env_var GRIST_OIDC_CLIENT_SECRET "$ENV_FILE")
        GRIST_API_KEY=$(read_env_var GRIST_API_KEY "$ENV_FILE")
        if [[ -z "$POSTGRES_KEYCLOAK_PASSWORD" ]]; then
            log_error "В $ENV_FILE нет POSTGRES_KEYCLOAK_PASSWORD, а файл существует. Исправьте .env или удалите том БД."
            exit 1
        fi
        log_success "Секреты загружены из существующего .env"
        return
    fi

    if [[ "$existing_pg_volume" == true ]] && [[ "$KEEP_DATA" == true ]]; then
        log_error "Найден Docker volume с данными PostgreSQL (keycloak-db-data), но нет $ENV_FILE с паролем БД."
        log_error "Keycloak не сможет подключиться: пароль в БД не совпадёт с новым."
        log_info "Варианты: (1) восстановите .env из бэкапа; (2) удалите том и разверните заново:"
        log_info "  cd $DEPLOY_DIR && docker compose --env-file .env down 2>/dev/null; docker volume rm \$(docker volume ls -q | grep keycloak-db-data)"
        exit 1
    fi

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

    if [[ "$VERBOSE" == true ]]; then
        log_verbose "Creating .env file at: $ENV_FILE"
        log_verbose "File permissions will be set to 600 (root only)"
    fi

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

    if [[ "$VERBOSE" == true ]]; then
        log_verbose ".env file created and permissions set to 600"
        log_verbose "File contents (redacted passwords):"
        sed 's/PASSWORD=.*/PASSWORD=***REDACTED***/g' "$ENV_FILE" | while read line; do
            log_verbose "  $line"
        done
    fi

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
# Сброс тома PostgreSQL (Keycloak)
################################################################################

reset_keycloak_postgres_volume() {
    log_step "Сброс тома PostgreSQL (Keycloak)"

    cd "$DEPLOY_DIR" || exit 1
    if [[ -f docker-compose.yml ]]; then
        log_info "Остановка контейнеров..."
        docker-compose --env-file .env down 2>/dev/null || docker-compose down 2>/dev/null || true
    fi

    local vols
    vols=$(docker volume ls -q 2>/dev/null | grep 'keycloak-db-data' || true)
    if [[ -z "$vols" ]]; then
        log_info "Том *keycloak-db-data не найден — удалять нечего."
        return 0
    fi

    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        log_warning "Удаление тома: $vol"
        if ! docker volume rm "$vol" 2>/dev/null; then
            log_error "Не удалось удалить $vol — остановите контейнеры: docker-compose --env-file .env down"
            exit 1
        fi
    done <<< "$vols"

    log_success "Том PostgreSQL для Keycloak удалён. При следующем запуске БД создастся заново с паролем из .env."
}

################################################################################
# Запуск контейнеров
################################################################################

start_containers() {
    log_step "Запуск контейнеров Docker"

    cd "$DEPLOY_DIR"

    if [[ "$VERBOSE" == true ]]; then
        log_verbose "Current directory: $(pwd)"
        log_verbose "Docker compose file: $(pwd)/docker-compose.yml"
        log_verbose "Env file: $(pwd)/.env"
        log_verbose "Starting containers with --env-file .env flag"
    fi

    log_info "Запуск PostgreSQL и Keycloak..."

    if [[ "$VERBOSE" == true ]]; then
        log_verbose "Running: docker-compose --env-file .env up -d postgres-keycloak keycloak"
    fi

    docker-compose --env-file .env up -d postgres-keycloak keycloak

    if [[ "$VERBOSE" == true ]]; then
        log_verbose "Containers started, waiting for Keycloak to be ready..."
        log_verbose "Checking logs..."
        docker-compose logs keycloak 2>/dev/null | tail -5 | while read line; do
            log_verbose "  $line"
        done
    fi

    log_info "Ожидание Keycloak (максимум 5 минут)..."
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker-compose logs keycloak 2>/dev/null | grep -q "Running the server\|started in"; then
            log_success "Keycloak готов"
            if [[ "$VERBOSE" == true ]]; then
                log_verbose "Keycloak startup successful after $((attempt * 5)) seconds"
            fi
            break
        fi

        attempt=$((attempt + 1))
        if [[ "$VERBOSE" == true && $((attempt % 3)) == 0 ]]; then
            log_verbose "Attempt $attempt/60... checking logs"
            docker-compose logs keycloak 2>/dev/null | tail -2 | while read line; do
                log_verbose "  $line"
            done
        fi
        echo -ne "\r⏳ Попытка $attempt/$max_attempts..."
        sleep 5
    done

    if [ $attempt -eq $max_attempts ]; then
        log_warning "Keycloak не стартовал за 5 минут"
        log_info "Проверьте логи: docker-compose logs keycloak"
        if [[ "$VERBOSE" == true ]]; then
            log_verbose "Full Keycloak logs:"
            docker-compose logs keycloak | tail -50 | while read line; do
                log_verbose "  $line"
            done
        fi
        if docker-compose logs keycloak 2>/dev/null | grep -q 'password authentication failed'; then
            log_error "PostgreSQL отклоняет пароль пользователя keycloak: пароль в .env не совпадает с тем, что был при первом init тома."
            log_info "Повторите деплой с удалением тома и тем же .env (данные БД Keycloak будут сброшены):"
            log_info "  sudo $SCRIPT_DIR/deploy.sh ... --reset-postgres-volume"
            log_info "или вручную: cd $DEPLOY_DIR && docker-compose --env-file .env down && docker volume rm \$(docker volume ls -q | grep keycloak-db-data)"
        fi
        log_error "Развертывание прервано: Keycloak не готов"
        exit 1
    fi

    log_info "Запуск Grist..."

    if [[ "$VERBOSE" == true ]]; then
        log_verbose "Running: docker-compose --env-file .env up -d grist"
    fi

    docker-compose --env-file .env up -d grist

    if [[ "$VERBOSE" == true ]]; then
        log_verbose "Checking container status:"
        docker-compose ps | while read line; do
            log_verbose "  $line"
        done
    fi

    log_success "Все контейнеры запущены"
}

################################################################################
# Настройка Keycloak realm и OIDC client
################################################################################

setup_keycloak_realm() {
    log_step "Настройка Keycloak Realm и OIDC Client"

    cd "$DEPLOY_DIR"

    # Убедиться что переменные окружения установлены
    export KEYCLOAK_ADMIN_PASSWORD
    export GRIST_DOMAIN
    export AUTH_DOMAIN
    export EMAIL_HOST
    export EMAIL_PORT
    export EMAIL_USER
    export EMAIL_PASSWORD
    export KEYCLOAK_URL="http://localhost:8090"
    export GRIST_OIDC_CLIENT_SECRET_FILE="/tmp/grist-client-secret.txt"

    if [[ "$VERBOSE" == true ]]; then
        log_verbose "Setting up Keycloak realm with these environment variables:"
        log_verbose "  KEYCLOAK_URL: $KEYCLOAK_URL"
        log_verbose "  KEYCLOAK_ADMIN_PASSWORD: ***REDACTED***"
        log_verbose "  AUTH_DOMAIN: $AUTH_DOMAIN"
        log_verbose "  GRIST_DOMAIN: $GRIST_DOMAIN"
        log_verbose "  EMAIL_HOST: $EMAIL_HOST"
        log_verbose "  EMAIL_PORT: $EMAIL_PORT"
        log_verbose "  EMAIL_USER: $EMAIL_USER"
        log_verbose "  GRIST_OIDC_CLIENT_SECRET_FILE: $GRIST_OIDC_CLIENT_SECRET_FILE"
        log_verbose "Script location: $SCRIPT_DIR/scripts/keycloak-realm-setup.sh"
    fi

    log_info "Запуск скрипта настройки Keycloak..."

    # Запустить keycloak-realm-setup.sh
    if bash "$SCRIPT_DIR/scripts/keycloak-realm-setup.sh"; then
        if [[ "$VERBOSE" == true ]]; then
            log_verbose "Keycloak realm setup script completed successfully"
        fi
        log_success "Keycloak realm и OIDC client созданы"

        # Получить client secret из файла
        if [[ -f "$GRIST_OIDC_CLIENT_SECRET_FILE" ]]; then
            GRIST_OIDC_CLIENT_SECRET=$(cat "$GRIST_OIDC_CLIENT_SECRET_FILE")

            if [[ "$VERBOSE" == true ]]; then
                log_verbose "Client secret file found and read"
                log_verbose "Client secret (first 20 chars): ${GRIST_OIDC_CLIENT_SECRET:0:20}..."
            fi

            log_success "Client secret получен"

            # Обновить .env файл
            log_info "Обновление .env файла..."

            if [[ "$VERBOSE" == true ]]; then
                log_verbose "Before update, GRIST_OIDC_CLIENT_SECRET in .env:"
                grep GRIST_OIDC_CLIENT_SECRET "$DEPLOY_DIR/.env" | head -c 100 | while read line; do
                    log_verbose "  $line..."
                done
            fi

            sed -i "s/^GRIST_OIDC_CLIENT_SECRET=.*/GRIST_OIDC_CLIENT_SECRET=$GRIST_OIDC_CLIENT_SECRET/" "$DEPLOY_DIR/.env"

            if [[ "$VERBOSE" == true ]]; then
                log_verbose "After update, GRIST_OIDC_CLIENT_SECRET in .env:"
                grep GRIST_OIDC_CLIENT_SECRET "$DEPLOY_DIR/.env" | head -c 100 | while read line; do
                    log_verbose "  $line..."
                done
            fi

            # Пересоздать Grist контейнер с новым secret
            log_info "Перезагрузка Grist с новой конфигурацией OIDC..."

            if [[ "$VERBOSE" == true ]]; then
                log_verbose "Running: docker-compose down grist"
            fi

            docker-compose --env-file .env down grist

            if [[ "$VERBOSE" == true ]]; then
                log_verbose "Running: docker-compose --env-file .env up -d grist"
            fi

            docker-compose --env-file .env up -d grist

            log_info "Ожидание Grist (максимум 2 минуты)..."
            local max_attempts=24
            local attempt=0

            while [ $attempt -lt $max_attempts ]; do
                if curl -s http://localhost:3000 > /dev/null 2>&1; then
                    log_success "Grist готов"
                    if [[ "$VERBOSE" == true ]]; then
                        log_verbose "Grist is responding after $((attempt * 5)) seconds"
                    fi
                    break
                fi
                attempt=$((attempt + 1))
                if [[ "$VERBOSE" == true && $((attempt % 2)) == 0 ]]; then
                    log_verbose "Attempt $attempt/24... checking Grist status"
                fi
                echo -ne "\r⏳ Попытка $attempt/$max_attempts..."
                sleep 5
            done

            if [ $attempt -eq $max_attempts ]; then
                log_warning "Grist может не запуститься сразу, проверьте логи: docker-compose logs grist"
                if [[ "$VERBOSE" == true ]]; then
                    log_verbose "Grist startup timeout, showing last 20 lines of logs:"
                    docker-compose logs grist | tail -20 | while read line; do
                        log_verbose "  $line"
                    done
                fi
            fi

            # Очистить временный файл
            if [[ "$VERBOSE" == true ]]; then
                log_verbose "Removing temporary client secret file: $GRIST_OIDC_CLIENT_SECRET_FILE"
            fi
            rm -f "$GRIST_OIDC_CLIENT_SECRET_FILE"
        else
            log_error "Не удалось получить client secret"
            return 1
        fi
    else
        log_error "Ошибка при создании Keycloak realm"
        return 1
    fi
}

################################################################################
# nginx reverse proxy (HTTPS → Keycloak / Grist)
################################################################################

run_nginx_setup() {
    log_step "Настройка nginx reverse proxy"

    if [[ ! -f "$SCRIPT_DIR/scripts/setup-nginx.sh" ]]; then
        log_error "Не найден: $SCRIPT_DIR/scripts/setup-nginx.sh"
        return 1
    fi

    chmod +x "$SCRIPT_DIR/scripts/setup-nginx.sh" 2>/dev/null || true
    if DEPLOY_DIR="$DEPLOY_DIR" bash "$SCRIPT_DIR/scripts/setup-nginx.sh"; then
        log_success "nginx настроен: https://$AUTH_DOMAIN и https://$GRIST_DOMAIN"
    else
        log_warning "nginx не настроен. Нужны сертификаты Let's Encrypt:"
        log_info "  certbot certonly --nginx -d $AUTH_DOMAIN"
        log_info "  certbot certonly --nginx -d $GRIST_DOMAIN"
        log_info "Затем: sudo DEPLOY_DIR=$DEPLOY_DIR $SCRIPT_DIR/scripts/setup-nginx.sh"
        return 1
    fi
}

################################################################################
# Запуск тестов
################################################################################

run_tests() {
    log_step "Запуск тестов развертывания"

    cd "$DEPLOY_DIR"

    # Экспортировать переменные для скрипта тестирования
    export AUTH_DOMAIN
    export GRIST_DOMAIN
    export DEPLOY_DIR

    if bash "$SCRIPT_DIR/scripts/test-deployment.sh"; then
        log_success "Все тесты пройдены"
    else
        log_warning "Часть тестов не прошла (часто HTTP 404 по HTTPS, пока не настроен nginx перед контейнерами)."
        log_info "Сервисы в Docker: Keycloak http://127.0.0.1:8090, Grist http://127.0.0.1:3000 — для https://$AUTH_DOMAIN и https://$GRIST_DOMAIN нужен reverse proxy (nginx) и SSL."
    fi
}

################################################################################
# Вывод credentials и информации о развертывании
################################################################################

output_credentials() {
    log_step "Сохранение учетных данных"

    # Создать файл с учетными данными
    cat > "$CREDENTIALS_FILE" << EOF
================================================================================
GRIST + KEYCLOAK DEPLOYMENT CREDENTIALS
Дата: $(date)
================================================================================

🔐 KEYCLOAK ADMIN CREDENTIALS
────────────────────────────────────────────────────────────────────────────
URL: https://$AUTH_DOMAIN
Username: admin
Password: $KEYCLOAK_ADMIN_PASSWORD

⚠️  СОХРАНИТЕ ЭТОТ ФАЙЛ В БЕЗОПАСНОМ МЕСТЕ!
────────────────────────────────────────────────────────────────────────────

📋 OIDC CLIENT CONFIGURATION
────────────────────────────────────────────────────────────────────────────
Client ID: grist-client
Client Secret: $GRIST_OIDC_CLIENT_SECRET
Issuer: https://$AUTH_DOMAIN/realms/grist
Redirect URI: https://$GRIST_DOMAIN/oauth2/callback

🔐 POSTGRESQL CREDENTIALS
────────────────────────────────────────────────────────────────────────────
Username: keycloak
Password: $POSTGRES_KEYCLOAK_PASSWORD
Database: keycloak

🎯 GRIST ADMIN EMAIL
────────────────────────────────────────────────────────────────────────────
Email: $GRIST_ADMIN_EMAIL
API Key: $GRIST_API_KEY

📧 EMAIL/SMTP CONFIGURATION
────────────────────────────────────────────────────────────────────────────
Host: $EMAIL_HOST
Port: $EMAIL_PORT
Username: $EMAIL_USER
From Address: $EMAIL_USER

================================================================================
IMPORTANT: These credentials are stored in plain text. Keep this file secure!
================================================================================
EOF

    chmod 600 "$CREDENTIALS_FILE"
    log_success "Учетные данные сохранены в: $CREDENTIALS_FILE"

    # Создать файл с информацией о развертывании
    cat > "$OUTPUT_FILE" << EOF
🎉 GRIST + KEYCLOAK DEVELOPMENT DEPLOYMENT
Дата: $(date)

================================================================================
✅ DEPLOYMENT COMPLETED SUCCESSFULLY
================================================================================

🌐 AVAILABLE SERVICES
────────────────────────────────────────────────────────────────────────────
Keycloak Admin Panel:
  URL: https://$AUTH_DOMAIN
  Username: admin
  Password: [see deploy-credentials.txt]

Grist Application:
  URL: https://$GRIST_DOMAIN
  Login: OIDC via Keycloak

================================================================================
📱 iOS/ANDROID INTEGRATION
================================================================================

Use this configuration in your mobile app:

{
  "grist_api_url": "https://$GRIST_DOMAIN",
  "grist_org": "$GRIST_ORG",
  "auth_type": "oidc",
  "oidc_issuer": "https://$AUTH_DOMAIN/realms/grist",
  "client_id": "grist-client",
  "redirect_uri": "app://grist-callback"
}

================================================================================
🔐 SECURITY NOTES
================================================================================

1. The .env file contains all sensitive data (passwords, secrets)
   Location: $DEPLOY_DIR/.env
   Permissions: 600 (root only)

2. deploy-credentials.txt contains a backup of all credentials
   Location: $CREDENTIALS_FILE
   Permissions: 600 (root only)

3. IMPORTANT: Store these credentials in a secure location:
   ✅ Password manager (1Password, Bitwarden, etc.)
   ✅ Encrypted storage
   ❌ NOT in Git repository
   ❌ NOT in plain text files
   ❌ NOT in email or Slack

4. The .gitignore file protects against accidentally committing secrets

================================================================================
📚 NEXT STEPS
================================================================================

1. Create users in Keycloak Admin Panel:
   https://$AUTH_DOMAIN → Realm: grist → Users → Create user

2. Create a test user:
   Email: test@example.com
   Password: [set a password]
   Email Verified: ON

3. Login to Grist:
   https://$GRIST_DOMAIN
   Click "Sign in"
   Use your Keycloak credentials

4. For mobile app integration:
   Use the JSON configuration above in GristConfig

================================================================================
🆘 TROUBLESHOOTING
================================================================================

Check the logs:
  docker-compose logs keycloak
  docker-compose logs grist
  tail -f /tmp/grist-keycloak-deploy.log

Run diagnostics:
  bash $DEPLOY_DIR/scripts/test-deployment.sh

See documentation:
  $DEPLOY_DIR/docs/TROUBLESHOOTING.md
  $DEPLOY_DIR/docs/FAQ.md

================================================================================
💾 BACKUP & RESTORE
================================================================================

Backup PostgreSQL database:
  docker exec grist-sso-postgres pg_dump -U keycloak keycloak > keycloak-backup.sql

Backup Grist data:
  docker run --rm -v grist-sso_grist-data:/data -v \$(pwd):/backup \\
    alpine tar czf /backup/grist-backup.tar.gz -C /data .

Backup configuration:
  cp $DEPLOY_DIR/.env backup/.env
  cp $CREDENTIALS_FILE backup/deploy-credentials.txt

See $DEPLOY_DIR/docs/FAQ.md for restore procedures.

================================================================================
Generated by Grist + Keycloak Deployment Script v1.0
================================================================================
EOF

    chmod 600 "$OUTPUT_FILE"
    log_success "Детали развертывания сохранены в: $OUTPUT_FILE"

    # Вывести информацию в консоль
    echo ""
    cat "$OUTPUT_FILE"
}

main() {
    # Инициализация логирования
    > "$LOG_FILE"

    log_step "Grist + Keycloak Deployment Script"
    log_info "Дата: $(date)"

    if [[ "$VERBOSE" == true ]]; then
        log_verbose "Verbose mode enabled"
        log_verbose "Script directory: $SCRIPT_DIR"
        log_verbose "Deploy directory: $DEPLOY_DIR"
        log_verbose "Log file: $LOG_FILE"
    fi

    # Обработка аргументов
    parse_arguments "$@"

    if [[ "$VERBOSE" == true ]]; then
        log_verbose "Parsed arguments:"
        log_verbose "  AUTH_DOMAIN: $AUTH_DOMAIN"
        log_verbose "  GRIST_DOMAIN: $GRIST_DOMAIN"
        log_verbose "  EMAIL_USER: $EMAIL_USER"
        log_verbose "  EMAIL_HOST: $EMAIL_HOST"
        log_verbose "  GRIST_ADMIN_EMAIL: $GRIST_ADMIN_EMAIL"
        log_verbose "  CERTBOT_EMAIL: $CERTBOT_EMAIL"
        log_verbose "  ROLLBACK_MODE: $ROLLBACK_MODE"
        log_verbose "  KEEP_DATA: $KEEP_DATA"
        log_verbose "  RESET_POSTGRES_VOLUME: $RESET_POSTGRES_VOLUME"
        log_verbose "  SETUP_NGINX: $SETUP_NGINX"
    fi

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

    # Подготовка каталога до загрузки/генерации секретов (нужен путь к .env)
    setup_directories
    generate_secrets
    create_env_file
    create_docker_compose

    if [[ "$RESET_POSTGRES_VOLUME" == true ]]; then
        reset_keycloak_postgres_volume
    fi

    # Запуск контейнеров
    start_containers

    # Создание Keycloak realm и клиента
    setup_keycloak_realm

    # Тесты развертывания
    run_tests

    # Вывод credentials и QR кода
    output_credentials

    if [[ "$SETUP_NGINX" == true ]]; then
        run_nginx_setup || true
    fi

    log_step "Развертывание завершено!"
    log_success "Учетные данные сохранены в: $CREDENTIALS_FILE"
    log_info "Детали развертывания: $OUTPUT_FILE"
    log_info ""
    log_info "🌐 Доступные сервисы:"
    log_info "   Keycloak Admin: https://$AUTH_DOMAIN"
    log_info "   Grist App: https://$GRIST_DOMAIN"
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
