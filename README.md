# Grist + Keycloak Deployment

Автоматизированное развертывание Grist (база данных) + Keycloak (SSO) + PostgreSQL на Ubuntu 24 VPS в один клик.

## ✨ Особенности

- ✅ Полностью автоматизированное развертывание Docker (PostgreSQL, Keycloak, Grist)
- ✅ Генерация паролей и секретов; при повторном запуске с `KEEP_DATA` — загрузка из существующего `.env` (совместимость с томом БД)
- ✅ Опционально: **nginx** reverse proxy и HTTPS (`--setup-nginx`; нужны уже выпущенные сертификаты Let's Encrypt для доменов)
- ✅ Docker контейнеризация (легко обновлять)
- ✅ Интерактивный и CLI режимы
- ✅ Откатывание с сохранением данных
- ✅ Автоматические тесты после развертывания
- ✅ JSON в `deploy-output.txt` для интеграции мобильных клиентов (отдельный QR-файл не создаётся)
- ✅ OIDC SSO для Grist

## 🚀 Быстрый старт

### Требования

- Ubuntu 24.04 LTS
- Минимум 2 GB RAM
- 10 GB свободного места на диске
- Root доступ (sudo)
- Домены должны быть зарегистрированы и указывать на VPS

### Интерактивный режим (рекомендуется)

```bash
sudo bash deploy.sh
```

Скрипт задаст вам все необходимые вопросы и автоматически настроит всё.

### CLI режим (с параметрами)

```bash
sudo bash deploy.sh \
  --auth-domain auth.example.com \
  --grist-domain grist.example.com \
  --email-user noreply@gmail.com \
  --email-password "your-app-password" \
  --grist-admin-email admin@example.com \
  --certbot-email admin@example.com \
  --setup-nginx
```

`--setup-nginx` записывает конфиг в `/etc/nginx/sites-available/grist-sso.conf` и проксирует на Keycloak (`127.0.0.1:8090`) и Grist (`127.0.0.1:3000`). Перед этим выпустите сертификаты, например: `sudo certbot certonly --nginx -d auth.example.com` и `-d grist.example.com`.

## 📋 Что спрашивает скрипт

| Параметр | Описание | Пример |
|----------|---------|--------|
| **AUTH_DOMAIN** | Домен для Keycloak | `auth.example.com` |
| **GRIST_DOMAIN** | Домен для Grist | `grist.example.com` |
| **EMAIL_USER** | Email для SMTP (может быть Gmail) | `noreply@gmail.com` |
| **EMAIL_PASSWORD** | Пароль/App Password для SMTP | `xxxx xxxx xxxx xxxx` |
| **GRIST_ADMIN_EMAIL** | Email админа Grist | `admin@example.com` |
| **CERTBOT_EMAIL** | Email для Let's Encrypt уведомлений | `admin@example.com` |

### Где взять Email Password?

**Для Gmail:**
1. Включить 2FA: https://myaccount.google.com/security
2. Генерировать App Password: https://myaccount.google.com/apppasswords
3. Скопировать пароль (16 символов с пробелами)

**Для других SMTP сервисов:**
- Обычный пароль аккаунта

## 🔄 Что происходит во время развертывания

```
1. ✅ Проверка requirements (Docker, curl, openssl, git, jq и т.д.)
2. ✅ Загрузка секретов из существующего .env (если есть и KEEP_DATA) или генерация новых
3. ✅ Создание .env и docker-compose.yml
4. ✅ Опционально: сброс тома PostgreSQL (--reset-postgres-volume)
5. ✅ Запуск контейнеров (PostgreSQL → Keycloak → Grist)
6. ✅ Ожидание Keycloak (до ~5 минут)
7. ✅ scripts/keycloak-realm-setup.sh: realm, SMTP (отдельным PUT), OIDC client, secret
8. ✅ Обновление .env с client secret и перезапуск Grist
9. ✅ Если указан --setup-nginx: nginx reverse proxy (до HTTPS-тестов)
10. ✅ Запуск scripts/test-deployment.sh
11. ✅ deploy-credentials.txt и deploy-output.txt (JSON для клиентов)
```

## 📂 Структура файлов

После успешного развертывания в `/opt/grist-sso/`:

```
/opt/grist-sso/
├── .env                           # Конфигурация (chmod 600)
├── docker-compose.yml             # Docker Compose файл
├── deploy-credentials.txt          # Все пароли и ключи (chmod 600)
└── deploy-output.txt              # Полный отчёт и JSON для мобильных клиентов
```

## 🔐 После развертывания

### 1. Keycloak Admin Panel

URL: `https://auth.example.com`

Credentials:
```
Username: admin
Password: [смотреть в deploy-credentials.txt]
```

### 2. Grist

URL: `https://grist.example.com`

Логин через Keycloak (OIDC SSO).

### 3. Интеграция с iOS приложением

В `deploy-output.txt` есть JSON (поля совпадают с тем, что пишет `deploy.sh`; `grist_org` — из переменной `GRIST_ORG`):

```json
{
  "grist_api_url": "https://grist.example.com",
  "grist_org": "ssa",
  "auth_type": "oidc",
  "oidc_issuer": "https://auth.example.com/realms/grist",
  "client_id": "grist-client",
  "redirect_uri": "app://grist-callback"
}
```

Идентификаторы workspace и документов в приложении задаются отдельно под вашу схему данных.

## 🔄 Откатывание (откат развертывания)

### Сохранить данные (рекомендуется)

```bash
sudo bash deploy.sh --rollback --keep-data
```

Удалит контейнеры и Nginx конфиги, но сохранит:
- БД Keycloak и Grist (volumes)
- .env и credentials файлы
- SSL сертификаты

При повторном развертывании всё восстановится.

### Полная очистка (⚠️ опасно!)

```bash
sudo bash deploy.sh --rollback --delete-all
```

Удалит всё, включая БД. **НЕВОЗМОЖНО ВОССТАНОВИТЬ.**

## 🧪 Тестирование развертывания

После завершения скрипта тесты запускаются автоматически. Вручную (из **клонированного репозитория**, не из `/opt/grist-sso` — там нет `scripts/`):

```bash
cd /path/to/grist-keycloak
set -a && source /opt/grist-sso/.env && set +a
export AUTH_DOMAIN GRIST_DOMAIN
bash scripts/test-deployment.sh
```

Проверяет (см. `scripts/test-deployment.sh`): DNS, контейнеры, HTTPS Keycloak/Grist, OIDC discovery, SSL по доменам, PostgreSQL, SMTP в Keycloak (эвристика), редирект OIDC с Grist. Тест портов `nc` в скрипте есть, но **в прогон не входит** — не дублирует проверку HTTPS.

## 📊 Мониторинг

### Логи контейнеров

```bash
cd /opt/grist-sso

# Keycloak
docker-compose logs -f keycloak

# Grist
docker-compose logs -f grist

# PostgreSQL
docker-compose logs -f postgres-keycloak
```

### Статус контейнеров

```bash
docker-compose ps
```

### Использование ресурсов

```bash
docker stats
```

## 🛠️ Обновление версий

### Обновить Keycloak

```bash
# Отредактировать docker-compose.yml
nano /opt/grist-sso/docker-compose.yml

# Изменить строку:
# image: quay.io/keycloak/keycloak:24.0
# на:
# image: quay.io/keycloak/keycloak:25.0

# Пересоздать контейнер
cd /opt/grist-sso
docker-compose down keycloak
docker-compose up -d keycloak
```

### Обновить Grist

```bash
# Аналогично для Grist
nano /opt/grist-sso/docker-compose.yml

# Изменить:
# image: gristlabs/grist:latest

cd /opt/grist-sso
docker-compose down grist
docker-compose up -d grist
```

## 📱 Конфигурация iOS приложения

После развертывания в `deploy-output.txt` есть JSON для `GristFunctionProcessor.swift`:

```swift
import Foundation

struct GristConfig {
    let apiUrl: String
    let orgId: String
    let workspaceId: Int
    let oidcIssuer: String
    let clientId: String
    let redirectUri: String
    
    static let production = GristConfig(
        apiUrl: "https://grist.example.com",
        orgId: "ssa",
        workspaceId: 3,
        oidcIssuer: "https://auth.example.com/realms/grist",
        clientId: "grist-client",
        redirectUri: "app://grist-callback"
    )
}

// В GristFunctionProcessor:
class GristFunctionProcessor {
    private let config = GristConfig.production
    
    func loginWithKeycloak() {
        // Реализовать OIDC flow с использованием ASWebAuthenticationSession
        // ...
    }
}
```

## ❓ Часто задаваемые вопросы

### Что делать если Keycloak не стартует?

```bash
# Проверить логи
docker logs grist-sso-keycloak

# Проверить память
free -h

# Проверить диск
df -h

# Перезагрузить контейнер
docker-compose restart keycloak
```

### Как сбросить пароль админа Keycloak?

```bash
docker exec -it grist-sso-keycloak /opt/keycloak/bin/kcadm.sh \
  update-users \
  --config-dir /tmp \
  --server http://localhost:8080 \
  --realm master \
  -u admin \
  -p password \
  --set-password newpassword \
  admin
```

### Как создать нового пользователя в Keycloak?

1. Открыть Admin Panel: `https://auth.example.com`
2. Перейти в `Realm: grist` → Users → Create user
3. Заполнить email
4. Вкладка `Credentials` → Set password

### Как дать права пользователю на таблицу в Grist?

1. Логиниться в Grist как админ
2. Создать документ/таблицу
3. Кликнуть на меню документа → Share
4. Добавить email пользователя с нужными правами

## 🐛 Troubleshooting

### OIDC Login fails: "Invalid client credentials"

**Решение:** Client secret не совпадает. Проверить в Keycloak:
1. https://auth.example.com → grist → Clients → grist-client → Credentials
2. Скопировать secret
3. Обновить .env: `GRIST_OIDC_CLIENT_SECRET=...`
4. Пересоздать Grist: `docker-compose restart grist`

### Email не отправляются

1. Проверить SMTP конфиг в Keycloak Admin Panel
2. Проверить что пароль правильный (особенно для Gmail)
3. Проверить порт (обычно 587 для TLS)

### Сертификаты не выдаются

```bash
sudo certbot renew --force-renewal
sudo systemctl reload nginx
```

## 📞 Поддержка

Документация: в клоне репозитория `docs/` (например `docs/FAQ.md`, `docs/TROUBLESHOOTING.md`)

Логи развертывания: `/tmp/grist-keycloak-deploy.log`

Credentials: `/opt/grist-sso/deploy-credentials.txt` (защищён с chmod 600)

## 📄 Лицензия

MIT

---

**Версия скрипта:** 1.0  
**Дата обновления:** 2026-04-09  
**Совместимость:** Ubuntu 24.04 LTS+
