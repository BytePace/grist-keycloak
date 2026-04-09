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

2. **Запустить диагностику:**
   ```bash
   bash /opt/grist-sso/scripts/test-deployment.sh
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
