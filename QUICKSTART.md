# 🚀 QUICKSTART - Быстрый старт в 5 минут

## Шаг 1: Подготовка

### Требования

- ✅ Ubuntu 24.04 LTS VPS
- ✅ Root доступ (sudo)
- ✅ 2 домена (auth.example.com, grist.example.com)
- ✅ Доступ в интернет

### Выбрать хостинга:

Любой хостинг с Ubuntu 24:
- Hetzner (€2-5/месяц)
- DigitalOcean (€5/месяц)
- Linode (€5/месяц)
- AWS, GCP, Azure и т.д.

### Настроить DNS:

1. Купить домены (или использовать существующие)
2. Добавить A record, указывающий на IP вашего сервера:
   ```
   auth.example.com      A  123.45.67.89
   grist.example.com     A  123.45.67.89
   ```
3. Дождаться распространения DNS (обычно 5-10 минут)

---

## Шаг 2: Запустить развертывание

### SSH на сервер

```bash
ssh root@YOUR_VPS_IP
```

### Клонировать репо

```bash
cd /tmp
git clone https://github.com/bytepace/grist-keycloak.git
cd grist-keycloak
```

### Запустить скрипт

```bash
sudo bash deploy.sh
```

### Ответить на вопросы

```
📝 Домен для Keycloak (например: auth.example.com): auth.example.com
📝 Домен для Grist (например: grist.example.com): grist.example.com
📝 Email для SMTP (например: noreply@gmail.com): your-email@gmail.com
🔐 Пароль/App Password для SMTP: xxxx xxxx xxxx xxxx
📝 Email администратора Grist: admin@example.com
📝 Email для Let's Encrypt (для уведомлений об истечении): admin@example.com
```

### Дождаться завершения

Примерно **10-15 минут**:
- Контейнеры загружаются
- Keycloak стартует
- Тесты запускаются

**HTTPS:** `deploy.sh` не выпускает сертификаты. Перед продакшеном: certbot для доменов, затем повторный запуск с **`--setup-nginx`** (или `scripts/setup-nginx.sh`). Иначе Keycloak/Grist доступны по HTTP только на localhost за reverse proxy.

```
✅ Развертывание завершено!

📋 Файлы конфигурации:
   - /opt/grist-sso/.env
   - /opt/grist-sso/deploy-credentials.txt ← 🔐 SAVE THIS!
   - /opt/grist-sso/deploy-output.txt

🌐 Доступные сервисы:
   - Keycloak Admin: https://auth.example.com
   - Grist App: https://grist.example.com
```

---

## Шаг 3: Первый вход

### Keycloak Admin Panel

**URL:** `https://auth.example.com`

**Credentials:**
```
Username: admin
Password: [смотреть в /opt/grist-sso/deploy-credentials.txt]
```

**Что сделать:**
1. Открыть https://auth.example.com
2. Войти с admin credentials
3. Перейти в Realm: **grist**
4. Создать пользователей для вашей команды

### Создать тестового пользователя

1. **Keycloak Admin** → Users → Create user
2. Заполнить:
   - Username: `test@example.com`
   - Email: `test@example.com`
   - Email Verified: **ON**
3. **Create**
4. Вкладка **Credentials** → Set Password
5. Ввести пароль (например: `TestPassword123!`)
6. **Save**

### Grist App

**URL:** `https://grist.example.com`

**Первый вход:**
1. Открыть https://grist.example.com
2. Нажать "Sign in"
3. Войти через Keycloak:
   - Email: `test@example.com`
   - Password: (введённый пароль)
4. Вернулась в Grist

**Готово!** ✅

---

## Шаг 4: Интеграция с мобильным приложением

### Получить конфиг для iOS/Android

В файле `/opt/grist-sso/deploy-output.txt` есть JSON конфиг:

```json
{
  "grist_api_url": "https://grist.example.com",
  "grist_org": "ssa",
  "auth_type": "oidc",
  "oidc_issuer": "https://auth.example.com/realms/grist",
  "client_id": "grist-mobile",
  "redirect_uri": "com.bytepace.scan-it-to-google-sheets://oauth/callback"
}
```

`workspaceId` и прочие поля приложения — по вашей модели в коде iOS; в выводе деплоя их нет.

### Вставить в iOS приложение

Файл: `ssa-ios/SSA/Grist/GristConfig.swift` (или аналог)

```swift
struct GristConfig {
    static let production = GristOIDCConfig(
        apiUrl: "https://grist.example.com",
        orgId: "ssa",
        workspaceId: 3,
        oidcIssuer: "https://auth.example.com/realms/grist",
        clientId: "grist-mobile",
        redirectUri: "com.bytepace.scan-it-to-google-sheets://oauth/callback"
    )
}

// В GristFunctionProcessor использовать:
let config = GristConfig.production
```

---

## ⚙️ Основные команды

### Проверить статус

```bash
cd /opt/grist-sso
docker-compose ps
```

### Логи

```bash
# Keycloak
docker-compose logs -f keycloak

# Grist
docker-compose logs -f grist

# PostgreSQL
docker-compose logs -f postgres-keycloak
```

### Перезагрузить сервис

```bash
cd /opt/grist-sso

# Перезагрузить Keycloak
docker-compose restart keycloak

# Перезагрузить Grist
docker-compose restart grist

# Перезагрузить всё
docker-compose restart
```

### Откатить развертывание

```bash
cd /path/to/grist-keycloak
sudo bash deploy.sh --rollback --keep-data
```

---

## 🔐 ВАЖНО: Сохраните credentials!

После развертывания **обязательно** сохраните:

```
/opt/grist-sso/deploy-credentials.txt
/opt/grist-sso/.env
```

**Где сохранить:**
- ✅ Password manager (1Password, Bitwarden, KeePass)
- ✅ Зашифрованное хранилище
- ✅ Документ с ограниченным доступом

**⚠️ НЕ сохранять:**
- ❌ В Git repo
- ❌ В текстовом файле на компьютере
- ❌ В email
- ❌ В Slack/Teams

---

## ❓ Что если что-то сломалось?

### 1. Проверить диагностику

```bash
cd /path/to/grist-keycloak
set -a && source /opt/grist-sso/.env && set +a
export AUTH_DOMAIN GRIST_DOMAIN
bash scripts/test-deployment.sh
```

### 2. Посмотреть логи

```bash
docker-compose logs keycloak | tail -50
docker-compose logs grist | tail -50
```

### 3. Найти решение

- 📖 **Документация**: в клоне репозитория `docs/TROUBLESHOOTING.md`, `docs/FAQ.md`
- 🔧 **Общие проблемы**: раздел ниже

---

## 🆘 Частые проблемы

### Keycloak не стартует

```bash
# Проверить логи
docker logs grist-sso-keycloak

# Может быть недостаточно памяти
free -h

# Перезагрузить
docker-compose down keycloak
docker-compose up -d keycloak
docker logs -f grist-sso-keycloak
```

### OIDC login fails

Обычно это значит неправильный `client_secret`.

```bash
# 1. Получить secret из Keycloak
# https://auth.example.com → grist → Clients → grist-client → Credentials

# 2. Обновить .env
nano /opt/grist-sso/.env
# GRIST_OIDC_CLIENT_SECRET=правильный_secret

# 3. Пересоздать Grist
docker-compose down grist
docker-compose up -d grist
```

### Email не отправляются

Проверить SMTP конфиг в Keycloak:
- `https://auth.example.com` → Realm settings → Email

Если используется Gmail:
- Включить 2FA
- Генерировать App Password
- Обновить .env

### Сертификат не работает

```bash
# Обновить
sudo certbot renew --force-renewal

# Перезагрузить Nginx
sudo systemctl reload nginx
```

Больше решений в `docs/TROUBLESHOOTING.md` (в клоне репозитория)

---

## 📚 Следующие шаги

После успешного развертывания:

1. ✅ **Создать пользователей** в Keycloak Admin
2. ✅ **Создать документы/таблицы** в Grist
3. ✅ **Дать доступ** пользователям (Share → Add user email)
4. ✅ **Интегрировать** с мобильным приложением
5. ✅ **Настроить бэкапы** (см. FAQ.md)
6. ✅ **Включить MFA** в Keycloak (дополнительная безопасность)

---

## 💬 Нужна помощь?

- 📖 **README.md** — полная документация
- 🆘 **TROUBLESHOOTING.md** — решение проблем
- ❓ **FAQ.md** — частые вопросы
- 🔗 **Grist Docs** — https://support.getgrist.com/
- 🔗 **Keycloak Docs** — https://www.keycloak.org/docs/latest/

---

**Congratulations!** 🎉 Grist + Keycloak развёрнут и готов к использованию!

Дальше всё зависит от вас — создавайте таблицы, автоматизируйте процессы и интегрируйте с вашими приложениями.

**Версия**: 1.0  
**Дата**: 2026-04-09
