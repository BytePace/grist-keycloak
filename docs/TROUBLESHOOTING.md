# Troubleshooting Guide

Решение типичных проблем при развертывании и использовании Grist + Keycloak.

## 🔴 Keycloak Issues

### Keycloak не стартует / зависает

**Симптомы:**
- Контейнер запущен, но логи не показывают "Running the server"
- Timeout при ожидании Keycloak

**Решение:**

```bash
# 1. Проверить логи
docker logs grist-sso-keycloak | tail -50

# 2. Проверить память
free -h

# 3. Если мало памяти, снизить JVM
nano /opt/grist-sso/docker-compose.yml
# Изменить JAVA_OPTS_APPEND на:
# JAVA_OPTS_APPEND: "-Xms128m -Xmx256m"

# 4. Пересоздать контейнер
cd /opt/grist-sso
docker-compose down keycloak
docker-compose up -d keycloak

# 5. Дождаться старта
docker-compose logs -f keycloak | grep "Running the server"
```

### PostgreSQL connection error

**Симптомы:**
```
FATAL: too many connections
```

**Решение:**

```bash
# 1. Перезагрузить PostgreSQL
docker-compose restart postgres-keycloak

# 2. Проверить использование connections
docker exec grist-sso-postgres psql -U keycloak -d keycloak -c "SELECT count(*) FROM pg_stat_activity;"

# 3. Если постоянно, увеличить max_connections в docker-compose.yml
```

### Admin Panel не доступен

**Симптомы:**
- Не может подключиться к https://auth.example.com/admin
- Connection timeout

**Решение:**

```bash
# 1. Проверить что домен разрешается
nslookup auth.example.com

# 2. Проверить Nginx
curl -I http://localhost:8090

# 3. Проверить контейнер
docker logs grist-sso-keycloak | grep -i "port\|bind"

# 4. Если DNS не разрешается, добавить в /etc/hosts (временно):
echo "YOUR_IP_ADDRESS auth.example.com" >> /etc/hosts
```

---

## 🔴 Grist Issues

### Grist не стартует с OIDC ошибкой

**Симптомы:**
```
Failed to initialize OIDC client: unauthorized_client
```

**Решение:**

```bash
# 1. Проверить что client_secret совпадает
cat /opt/grist-sso/.env | grep GRIST_OIDC

# 2. Проверить в Keycloak Admin:
# https://auth.example.com → grist → Clients → grist-client → Credentials

# 3. Если не совпадает, скопировать secret из Keycloak
# и обновить .env:
nano /opt/grist-sso/.env
# GRIST_OIDC_CLIENT_SECRET=новый_secret

# 4. Пересоздать Grist
docker-compose restart grist
docker logs -f grist-sso-grist
```

### Sign-in failed: «Please verify your email with the identity provider»

**Симптомы:** После регистрации или входа через Keycloak Grist показывает сообщение о необходимости подтвердить email, хотя в realm отключена верификация почты.

**Причина:** Это проверка на стороне **Grist**, не Keycloak. Grist по умолчанию требует, чтобы в ответе OIDC userinfo поле `email_verified` было `true`. У новых пользователей Keycloak часто отдаёт `email_verified: false`, пока email не подтверждён через поток Keycloak — независимо от настройки «Verify email» в realm.

**Варианты:**

1. **Рекомендуется для открытой регистрации без писем:** задать для контейнера Grist переменную окружения  
   `GRIST_OIDC_SP_IGNORE_EMAIL_VERIFIED=true`  
   ([документация Grist OIDC](https://support.getgrist.com/install/oidc/)). В этом репозитории:
   - добавьте в `/opt/grist-sso/.env` строку `GRIST_OIDC_SP_IGNORE_EMAIL_VERIFIED=true` и перегенерируйте `docker-compose.yml` через `deploy.sh`, **или**
   - при следующем деплое: `sudo ./deploy.sh ... --ignore-email-verified`  
   Затем: `cd /opt/grist-sso && docker compose --env-file .env up -d grist`

2. **Строже по безопасности:** оставить проверку и в Keycloak для пользователя включить **Email verified** (Users → пользователь → Details) или включить подтверждение email в realm.

### Access denied: «You do not have access to this organization's documents»

**Симптомы:** Пользователь успешно вошёл через OIDC (Keycloak), но на `/o/<slug>/` Grist пишет, что нет доступа к документам организации.

**Причина:** **Аутентификация** (кто вы — Keycloak) и **авторизация** (членство в team site / organization в Grist) — разные вещи. При `GRIST_SINGLE_ORG` новые учётки **не добавляются в команду автоматически**: их нужно пригласить или добавить как участников team site. Отдельно: в контейнер Grist должна быть передана **`GRIST_DEFAULT_EMAIL`** — email владельца инстанса и создателя single-org ([Self-managed Grist](https://support.getgrist.com/self-managed/)); в свежих версиях `deploy.sh` она задаётся из email администратора деплоя.

**Что сделать:**

1. Зайти под **администратором Grist** (тот же email, что в `GRIST_DEFAULT_EMAIL` / `GRIST_ADMIN_EMAIL` при деплое) → открыть организацию → **Manage Team** / управление командой → **пригласить** пользователей по email или добавить уже существующих пользователей сайта. Подробнее: [Team sharing](https://support.getgrist.com/team-sharing/).

2. Убедиться, что в `docker-compose` у сервиса `grist` есть `GRIST_DEFAULT_EMAIL` и `GRIST_SINGLE_ORG`, перезапустить контейнер после правок.

3. Полностью автоматического «все пользователи Keycloak сразу members» в типичной конфигурации Grist CE нет; для массового провижининга смотрите **SCIM** и документацию вашей редакции Grist.

### Login redirects to Keycloak but fails

**Симптомы:**
- Вводишь email/пароль в Keycloak
- Вернулась ошибка "Something went wrong"

**Решение:**

```bash
# 1. Проверить логи Grist
docker logs grist-sso-grist | grep -i "oidc\|callback"

# 2. Проверить что пользователь существует в Keycloak
# https://auth.example.com → grist → Users

# 3. Убедиться что пароль установлен (не временный)
# Users → [user] → Credentials → Set Password

# 4. Проверить что email верифицирован
# Users → [user] → Email Verified = ON

# 5. Проверить OIDC client конфигурацию:
# Clients → grist-client → Valid Redirect URIs
# Должна содержать: https://grist.example.com/oauth2/callback
```

### Нативное приложение (iOS/Android): отдельный клиент `grist-mobile`

**Не используйте** `grist-client` в мобильном приложении: это **confidential** client с секретом для контейнера Grist.

Скрипт `scripts/keycloak-realm-setup.sh` создаёт **public** client **`grist-mobile`** с **PKCE (S256)** и redirect вида  
`com.bytepace.scan-it-to-google-sheets://oauth/callback` (переопределение: `GRIST_MOBILE_OIDC_REDIRECT_URI`).

Проверка в Keycloak: Realm **grist** → **Clients** → **grist-mobile** → **Valid redirect URIs** содержит тот же URI, что в приложении; **Client authentication** = Off; **Proof Key for Code Exchange** = S256.

### Sign out из Grist: Keycloak «Invalid redirect uri» на logout

**Симптомы:** При выходе из Grist открывается  
`/realms/grist/protocol/openid-connect/logout?post_logout_redirect_uri=https://grist…/signed-out&…`  
и Keycloak показывает **Invalid redirect uri**.

**Причина:** с Keycloak 18+ для параметра `post_logout_redirect_uri` действует отдельный список — **Valid post logout redirect URIs** / атрибут клиента `post.logout.redirect.uris`. Обычных **Valid Redirect URIs** (например `/oauth2/callback`) для выхода недостаточно.

**Решение:**

1. **Через Admin Console:** Realm **grist** → **Clients** → **grist-client** → вкладка **Settings** / **Logout** (зависит от версии) → в **Valid post logout redirect URIs** добавьте точно:  
   `https://<GRIST_DOMAIN>/signed-out`  
   (для `grist.bytepace.com` это `https://grist.bytepace.com/signed-out`). Сохраните.

2. **Через обновлённый `scripts/keycloak-realm-setup.sh`:** при следующем прогоне деплоя скрипт выставляет `post.logout.redirect.uris` для клиента автоматически. Либо выполните скрипт вручную с экспортом `GRIST_DOMAIN` и `AUTH_DOMAIN`, как при установке.

**Обходной путь на стороне Grist:** переменная `GRIST_OIDC_IDP_SKIP_END_SESSION_ENDPOINT=true` отключает редирект на logout IdP (сессия Keycloak может остаться активной) — предпочтительнее исправить клиент в Keycloak.

### OIDC Configuration Error

**Симптомы:**
```
OIDC callback failed: OPError: unauthorized_client
Invalid client or Invalid client credentials
```

**Решение:**

Это значит что Keycloak отклонил запрос от Grist.

```bash
# 1. Проверить Keycloak logs
docker logs grist-sso-keycloak | grep -i "unauthorized\|credentials"

# 2. Проверить что client "grist-client" создан
curl -s -k https://auth.example.com/realms/grist/.well-known/openid-configuration | jq '.issuer'

# 3. Проверить что client_id и client_secret совпадают
# Keycloak: Clients → grist-client → Credentials → Client Secret
# .env: GRIST_OIDC_CLIENT_SECRET

# 4. Если что-то не совпадает, пересоздать client в Keycloak
# Clients → grist-client → Delete
# Затем запустить setup скрипт
cd /opt/grist-sso
source .env
bash scripts/keycloak-realm-setup.sh
```

---

## 🔴 SSL / HTTPS Issues

### Certificate not valid

**Симптомы:**
- Browser shows "Certificate expired" or "Not secure"
- HTTPS connection fails

**Решение:**

```bash
# 1. Проверить сертификат
openssl s_client -connect auth.example.com:443 </dev/null 2>/dev/null | openssl x509 -noout -dates

# 2. Обновить сертификат
sudo certbot renew --force-renewal

# 3. Перезагрузить Nginx
sudo systemctl reload nginx

# 4. Если всё ещё проблема, удалить и пересоздать
sudo certbot delete --cert-name auth.example.com
sudo certbot --nginx -d auth.example.com
sudo systemctl reload nginx
```

### Nginx redirect loop

**Симптомы:**
```
Redirect loop detected / Too many redirects
```

**Решение:**

```bash
# 1. Проверить Nginx конфиги
cat /etc/nginx/sites-enabled/auth.bytepace.com.conf

# 2. Убедиться что нет дублирующихся редиректов
# Должно быть только:
# http → https редирект
# НЕ должно быть циклических редиректов

# 3. Перезагрузить Nginx
sudo nginx -t
sudo systemctl reload nginx
```

---

## 🔴 Email Issues

### SMTP connection error

**Симптомы:**
```
Couldn't connect to host, port: smtp.gmail.com, 587
UnknownHostException
```

**Решение:**

```bash
# 1. Проверить DNS
nslookup smtp.gmail.com

# 2. Проверить что EMAIL_HOST правильный
cat /opt/grist-sso/.env | grep EMAIL_

# 3. Если используется Gmail, проверить:
# - 2FA включена
# - App Password создан
# - Пароль скопирован правильно (без ошибок)

# 4. Проверить SMTP конфиг в Keycloak
# Admin Panel → Realm: grist → Email
# Проверить хост, порт, TLS, username, password

# 5. Протестировать SMTP вручную
telnet smtp.gmail.com 587
# Должно показать: 220 ...
```

### SMTP authentication error

**Симптомы:**
```
authentication failed / Invalid credentials
```

**Решение:**

```bash
# 1. Если Gmail:
# - Перейти https://myaccount.google.com/apppasswords
# - Создать новый App Password
# - Скопировать новый пароль

# 2. Обновить .env
nano /opt/grist-sso/.env
# EMAIL_PASSWORD=новый_пароль

# 3. Пересоздать контейнер
docker-compose down keycloak
docker-compose up -d keycloak

# 4. Проверить логи
docker logs grist-sso-keycloak | grep -i "smtp\|email"
```

---

## 🔴 Database Issues

### Database migration error

**Симптомы:**
```
Database migration failed
```

**Решение:**

```bash
# 1. Проверить что PostgreSQL работает
docker exec grist-sso-postgres pg_isready

# 2. Проверить БД
docker exec grist-sso-postgres psql -U keycloak -d keycloak -c "\dt"

# 3. Если БД повреждена, откатить с сохранением (осторожно!)
docker-compose down
docker volume ls | grep grist
# Backup перед удалением!
docker volume rm grist-sso_keycloak-db-data
docker-compose up -d

# 4. Если нужно только переинициализировать Keycloak:
docker-compose down keycloak postgres-keycloak
docker volume rm grist-sso_keycloak-db-data
docker-compose up -d postgres-keycloak keycloak
```

### PostgreSQL: password authentication failed for user "keycloak"

**Симптомы:** Keycloak в логах не подключается к БД; при первом запуске том PostgreSQL был инициализирован с одним паролем, а в `.env` сейчас другой.

**Причина:** Пароль в Docker volume задаётся при первом `init` тома; смена `POSTGRES_KEYCLOAK_PASSWORD` в `.env` без пересоздания тома не меняет пароль внутри БД.

**Решение:**

1. Восстановить в `.env` тот пароль, что использовался при первом успешном деплое (из бэкапа `deploy-credentials.txt`), **или**
2. Осознанно сбросить данные БД:  
   `sudo bash deploy.sh ... --reset-postgres-volume`  
   (удалит том PostgreSQL для Keycloak; сделайте бэкап, если данные нужны).

При повторном деплое с `KEEP_DATA` скрипт подхватывает секреты из существующего `.env` — не перезаписывайте пароль БД случайно, если том уже есть.

---

## 🔴 Network Issues

### Ports already in use

**Симптомы:**
```
Bind for 127.0.0.1:8090 failed: port is already allocated
```

**Решение:**

```bash
# 1. Найти процесс на этом порту
sudo lsof -i :8090

# 2. Убить процесс
sudo kill -9 <PID>

# 3. ИЛИ изменить порт в docker-compose.yml
nano /opt/grist-sso/docker-compose.yml
# Изменить: "127.0.0.1:8090:8080" на "127.0.0.1:8091:8080"

# 4. Пересоздать контейнер
docker-compose down
docker-compose up -d
```

### Nginx: 404 или default welcome при открытии домена

**Симптомы:** `https://auth.example.com` отдаёт страницу по умолчанию nginx или 404, хотя контейнеры работают.

**Решение:**

```bash
# 1. Убедиться, что деплой выполнялся с --setup-nginx или вручную запущен scripts/setup-nginx.sh
sudo nginx -t
ls -la /etc/nginx/sites-enabled/grist-sso.conf

# 2. Проверить, что сертификаты есть в /etc/letsencrypt/live/<домен>/
sudo ls /etc/letsencrypt/live/

# 3. Перезагрузить nginx
sudo systemctl reload nginx
```

Контейнеры слушают только `127.0.0.1`; снаружи должен быть nginx (или другой reverse proxy) с путями к PEM из Let's Encrypt.

### DNS not resolving

**Симптомы:**
```
nslookup: command not found
```

**Решение:**

```bash
# 1. Установить dnsutils
sudo apt-get update
sudo apt-get install -y dnsutils

# 2. Проверить DNS сервер
cat /etc/resolv.conf

# 3. Если не работает, добавить публичный DNS
sudo echo "nameserver 8.8.8.8" >> /etc/resolv.conf
```

---

## 🔴 Permission Issues

### Permission denied on .env

**Симптомы:**
```
Permission denied: .env
```

**Решение:**

```bash
# Исправить permissions
sudo chmod 600 /opt/grist-sso/.env
sudo chmod 600 /opt/grist-sso/deploy-credentials.txt
sudo chown root:root /opt/grist-sso/.env

# Проверить
ls -la /opt/grist-sso/.env
# Должно быть: -rw------- 1 root root
```

---

## 🔴 Disk Space Issues

### Disk full / No space left

**Симптомы:**
```
No space left on device
```

**Решение:**

```bash
# 1. Проверить использование
df -h

# 2. Найти большие файлы
du -sh /* | sort -rh | head -10

# 3. Очистить Docker
docker system prune -a --volumes

# 4. Очистить логи
docker-compose down
sudo journalctl --vacuum=100M

# 5. Если нужно, переместить /opt/grist-sso на другой диск
sudo mv /opt/grist-sso /mnt/large-disk/grist-sso
sudo ln -s /mnt/large-disk/grist-sso /opt/grist-sso
```

---

## 📞 Getting Help

1. **Проверить логи:**
   ```bash
   docker-compose logs grist-sso-keycloak
   docker-compose logs grist-sso-grist
   docker-compose logs grist-sso-postgres
   tail -f /tmp/grist-keycloak-deploy.log
   ```

2. **Запустить диагностику** (скрипт в клоне репо, не в `/opt/grist-sso`):
   ```bash
   cd /path/to/grist-keycloak
   set -a && source /opt/grist-sso/.env && set +a
   export AUTH_DOMAIN GRIST_DOMAIN
   bash scripts/test-deployment.sh
   ```

3. **Проверить конфигурацию:**
   ```bash
   cat /opt/grist-sso/.env
   docker-compose config
   ```

4. **Собрать инфо для репорта:**
   ```bash
   # OS version
   lsb_release -a
   
   # Docker version
   docker --version
   docker-compose --version
   
   # Disk space
   df -h
   
   # Memory
   free -h
   
   # Container status
   docker-compose ps
   ```

---

**Версия**: 1.0  
**Последнее обновление**: 2026-04-09
