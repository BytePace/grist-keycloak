# FAQ - Часто Задаваемые Вопросы

## 🤔 Общие вопросы

### Что такое Grist?

Grist — это интерактивная таблица (как Google Sheets) с встроенным SQL, Python и API. Отлично подходит для:
- Сбора данных через формы
- Автоматизации бизнес-процессов
- Интеграции с внешними сервисами
- Кастомизации бизнес-логики

[Подробнее: https://www.getgrist.com/](https://www.getgrist.com/)

### Что такое Keycloak?

Keycloak — это открытый сервер идентификации и управления доступом (Identity & Access Management / IAM) с поддержкой:
- OIDC (OpenID Connect) — современный протокол аутентификации
- SAML 2.0
- OAuth 2.0
- Управление пользователями и ролями
- Multi-factor authentication (MFA)

[Подробнее: https://www.keycloak.org/](https://www.keycloak.org/)

### Почему именно Keycloak + Grist?

- **Keycloak** обеспечивает централизованное управление доступом (SSO)
- **Grist** предоставляет интерактивную БД с интеграциями
- Вместе они позволяют:
  - Одного пользователя разным приложением (SSO)
  - Контролировать права доступа к таблицам
  - Автоматизировать бизнес-процессы

---

## 🚀 Развертывание

### Сколько времени займет развертывание?

Примерно **10-15 минут** (без учёта ручного выпуска сертификатов certbot):
- 5 минут на запуск контейнеров
- 2 минуты на создание Keycloak realm/client
- остальное — тесты и вывод

### Какие требования к серверу?

- **ОС**: Ubuntu 24.04 LTS (или новее)
- **RAM**: минимум 2 GB (рекомендуется 4+ GB)
- **Диск**: 10 GB свободного места
- **CPU**: 2 ядра
- **Интернет**: открыт порт 443 (HTTPS) и 80 (HTTP)

### Можно ли развернуть на другом Linux дистрибутиве?

Скрипт проверяет Ubuntu. Теоретически может работать на Debian, но не тестировалось.

Если нужна поддержка, отредактируйте в `deploy.sh`:
```bash
if ! grep -qi "Ubuntu\|Debian" /etc/os-release; then
```

### Где мне взять домены для Auth и Grist?

1. Купить домен на registrar (GoDaddy, Namecheap, etc.)
2. Указать A record на IP адрес вашего VPS
3. Подождать пока DNS распространится (до 24 часов)
4. Проверить: `nslookup auth.example.com`

### Нужно ли мне иметь SSL сертификаты заранее?

**`deploy.sh` не вызывает certbot.** Для HTTPS снаружи:

1. Выпустите сертификаты Let's Encrypt для обоих доменов (например `sudo certbot certonly --nginx -d auth.example.com -d grist.example.com` или по одному домену — смотрите документацию certbot).
2. Запустите развертывание с **`--setup-nginx`** (или позже `sudo bash scripts/setup-nginx.sh` из клона репо), чтобы записать `grist-sso.conf` и проксировать на Keycloak/Grist на localhost.

Без nginx и сертификатов контейнеры слушают только локально (`127.0.0.1`); тесты HTTPS в `test-deployment.sh` ожидают доступность по доменам извне.

Email `CERTBOT_EMAIL` в интерактивном режиме нужен для уведомлений Let's Encrypt при ручном certbot, не как автозапуск certbot из `deploy.sh`.

---

## 🔐 Безопасность

### Где хранятся пароли после развертывания?

В двух местах:

**1. `.env` файл** (рабочий конфиг)
```
/opt/grist-sso/.env
Permissions: 600 (только root может читать)
```

**2. `deploy-credentials.txt`** (бэкап)
```
/opt/grist-sso/deploy-credentials.txt
Permissions: 600 (только root может читать)
```

**⚠️ Всегда сохраняйте в безопасном месте!**

### Как изменить пароль админа Keycloak?

**Через Admin Panel:**
1. Открыть https://auth.example.com
2. Нажать на профиль (правый верхний угол) → Manage account
3. Перейти в "Manage password"
4. Ввести новый пароль

**Через CLI:**
```bash
docker exec -it grist-sso-keycloak /opt/keycloak/bin/kcadm.sh \
  update-credentials \
  --server http://localhost:8080 \
  --realm master \
  -u admin \
  -p oldpassword \
  --password newpassword
```

### Безопасно ли хранить пароль SMTP в .env?

Технически безопасно, так как:
- `.env` имеет permissions 600 (только root)
- Находится в приватной директории `/opt/grist-sso`
- Не коммитится в git

**Но рекомендуется:**
- Использовать App Password для Gmail вместо основного пароля
- Регулярно менять пароли
- Не передавать .env другим людям

### Как контролировать доступ пользователей к таблицам?

1. **В Keycloak** (аутентификация):
   - Пользователь должен быть создан и активен

2. **В Grist** (авторизация):
   - Creator → Share документ
   - Указать email пользователя
   - Выбрать права (View, Edit, Owner)

Права могут быть:
- **View**: только чтение
- **Edit**: чтение и редактирование
- **Owner**: полный контроль

### Кто может создавать новых пользователей?

Только администратор (или другие админы):
1. https://auth.example.com (Keycloak)
2. Realm: grist → Users → Create user

Рядовые пользователи НЕ могут самостоятельно регистрироваться (User Registration отключена по умолчанию).

---

## 👥 Управление пользователями

### Как создать нового пользователя?

1. Открыть Keycloak Admin Panel: https://auth.example.com
2. Realm: grist → Users → Create user
3. Заполнить:
   - Username: email пользователя
   - Email: почта
   - Email Verified: ON
4. Нажать Create
5. Вкладка Credentials → Set Password
6. Ввести пароль и сохранить

### Можно ли разрешить пользователям самостоятельно регистрироваться?

Да, но нужно включить User Registration:

1. https://auth.example.com → Realm: grist
2. Вкладка "Realm settings"
3. Переключить "User registration" → ON
4. Сохранить

Теперь пользователи смогут создавать аккаунт самостоятельно.

### Как деактивировать пользователя?

1. https://auth.example.com → Realm: grist → Users
2. Кликнуть на пользователя
3. Переключить "Enabled" → OFF
4. Сохранить

Пользователь не сможет логиниться, но его данные сохранятся.

### Как удалить пользователя полностью?

1. https://auth.example.com → Realm: grist → Users
2. Кликнуть на пользователя
3. Нажать Delete (справа)
4. Подтвердить

**Осторожно:** это необратимо!

---

## 📱 Интеграция iOS/Android

### Как подключить мобильное приложение к Grist?

В `deploy-output.txt` после развертывания будет JSON конфиг:

```json
{
  "grist_api_url": "https://grist.example.com",
  "auth_type": "oidc",
  "oidc_issuer": "https://auth.example.com/realms/grist",
  "client_id": "grist-mobile",
  "redirect_uri": "com.bytepace.scan-it-to-google-sheets://oauth/callback"
}
```

Вставить в `GristFunctionProcessor.swift`:

```swift
let gristConfig: [String: Any] = [
    "grist_api_url": "https://grist.example.com",
    "auth_type": "oidc",
    "oidc_issuer": "https://auth.example.com/realms/grist",
    "client_id": "grist-mobile",
    "redirect_uri": "com.bytepace.scan-it-to-google-sheets://oauth/callback"
]
```

**Важно:** `grist-client` — confidential client для **сервера Grist** (есть секрет в `.env`). Для **ASWebAuthenticationSession** / PKCE в приложении используйте `grist-mobile` (создаётся `scripts/keycloak-realm-setup.sh`); секрет не нужен.

### Нужен ли API Key для мобильного приложения?

Если используется OIDC (SSO):
- **API Key НЕ нужен**
- Приложение получает `access_token` от Keycloak
- Token используется для запросов к Grist API

Если приложение не использует OIDC:
- Нужно создать API Key в Grist
- Гарантировать безопасное хранение

### Как создать API Key в Grist?

1. Логиниться в Grist: https://grist.example.com
2. Нажать на профиль (меню) → Settings
3. Перейти в "API Keys"
4. Нажать "Create new key"
5. Скопировать и сохранить

**⚠️ Никому не передавайте API Key!**

---

## 🔄 Обновления и обслуживание

### Как обновить Keycloak на новую версию?

```bash
cd /opt/grist-sso

# Отредактировать docker-compose.yml
nano docker-compose.yml
# Изменить: image: quay.io/keycloak/keycloak:24.0
# на:      image: quay.io/keycloak/keycloak:25.0

# Пересоздать контейнер
docker-compose down keycloak
docker-compose pull keycloak
docker-compose up -d keycloak

# Проверить логи
docker logs -f grist-sso-keycloak | grep "Running the server"
```

### Как обновить Grist?

Аналогично:

```bash
cd /opt/grist-sso
nano docker-compose.yml
# Изменить image для grist

docker-compose down grist
docker-compose pull grist
docker-compose up -d grist
```

### Нужно ли делать бэкапы?

**Да, обязательно!**

Бэкапируйте:

1. **PostgreSQL БД** (Keycloak):
```bash
docker exec grist-sso-postgres pg_dump -U keycloak keycloak > keycloak-backup.sql
```

2. **Grist data**:
```bash
docker run --rm -v grist-sso_grist-data:/data -v $(pwd):/backup \
  alpine tar czf /backup/grist-backup.tar.gz -C /data .
```

3. **.env конфиги**:
```bash
cp /opt/grist-sso/.env /backup/.env
cp /opt/grist-sso/deploy-credentials.txt /backup/deploy-credentials.txt
```

### Как восстановить из бэкапа?

```bash
# 1. Остановить контейнеры
cd /opt/grist-sso
docker-compose down

# 2. Удалить старые volumes
docker volume rm grist-sso_keycloak-db-data grist-sso_grist-data

# 3. Пересоздать volumes
docker volume create grist-sso_keycloak-db-data
docker volume create grist-sso_grist-data

# 4. Восстановить из бэкапа
docker run --rm -v grist-sso_keycloak-db-data:/data -v $(pwd):/backup \
  postgres:15-alpine psql -U keycloak keycloak < /backup/keycloak-backup.sql

docker run --rm -v grist-sso_grist-data:/data -v $(pwd):/backup \
  alpine tar xzf /backup/grist-backup.tar.gz -C /data

# 5. Перезапустить
docker-compose up -d
```

---

## 🆘 Когда что-то сломалось

### Скрипт упал с ошибкой, что делать?

1. **Проверить логи:**
   ```bash
   tail -f /tmp/grist-keycloak-deploy.log
   ```

2. **Откатить развертывание** (сохранив данные):
   ```bash
   sudo bash deploy.sh --rollback --keep-data
   ```

3. **Исправить проблему** (см. TROUBLESHOOTING.md)

4. **Пересоздать развертывание**:
   ```bash
   sudo bash deploy.sh
   ```

### Контейнеры не стартуют

```bash
# Проверить статус
docker-compose ps

# Проверить логи
docker-compose logs keycloak
docker-compose logs grist

# Попробовать перезагрузить
docker-compose down
docker-compose up -d

# Если всё ещё не работает
docker system prune -a --volumes
sudo bash deploy.sh
```

### Как получить поддержку?

1. **Чеклист проблем**: `docs/TROUBLESHOOTING.md` (в клоне репозитория)
2. **Диагностика**: из клона репозитория, с `AUTH_DOMAIN`/`GRIST_DOMAIN` (например после `source /opt/grist-sso/.env`), см. `README.md` → раздел тестирования
3. **Логи**: `/tmp/grist-keycloak-deploy.log` и `docker-compose logs`
4. **GitHub Issues**: [Grist issues](https://github.com/gristlabs/grist/issues)
5. **Keycloak Docs**: https://www.keycloak.org/docs/latest/

---

## 📊 Производительность

### Сколько пользователей может поддерживать установка?

На одном VPS с 2 GB RAM + 2 CPU:
- **До 100 пользователей**: без проблем
- **100-500 пользователей**: рекомендуется 4 GB RAM
- **500+ пользователей**: нужна горизонтальное масштабирование

### Как улучшить производительность?

1. **Увеличить RAM**:
   ```bash
   # Для Keycloak
   nano docker-compose.yml
   # JAVA_OPTS_APPEND: "-Xms512m -Xmx1g"
   ```

2. **Очистить старые логи**:
   ```bash
   docker exec grist-sso-postgres vacuumdb -U keycloak keycloak
   ```

3. **Включить кэширование в Nginx**:
   ```bash
   # Отредактировать Nginx конфиг
   nano /etc/nginx/sites-enabled/grist.bytepace.com.conf
   # Добавить: proxy_cache_valid 10m;
   ```

---

**Версия**: 1.0  
**Последнее обновление**: 2026-04-09
