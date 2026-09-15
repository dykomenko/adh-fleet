# Origin-нода (main)

Настраивается один раз. Дальше вы сюда заходите только чтобы поменять фильтры.

По тексту origin — это `node01`, номер 1, шлюз VPN `10.101.0.1`.

---

## 1. Консоль Netbird

Один раз, до того как трогать серверы. `app.netbird.io`:

1. **Группы** — `agh-origin` и `agh-replica`.
2. **Два setup key**, оба с auto-assign нужной группы:
   - для origin — auto-assign `agh-origin`, хватит одноразового;
   - для реплик — тип **Reusable**, auto-assign `agh-replica`, срок с запасом.

   Так группа назначается автоматически при подключении и руками в консоли
   ничего трогать не нужно.
3. **Истечение пиров — отключить.** Иначе через заданный срок ноды
   потребуют повторной интерактивной авторизации, и весь парк одновременно
   выпадет из оверлея. Снять и в настройках ключа, и в свойствах пиров.
4. **Политика доступа** — одно правило: `agh-origin` → `agh-replica`,
   протокол **TCP**, порт **3000**. Больше ничего открывать не нужно.

   Дефолтное правило `All → All` удалить. Оно оперирует группой `All`
   и потому не видно на вкладке Policies внутри группы — проверяйте
   на общей странице Access Control. Пока оно живо, ваша политика
   ничего не ограничивает.

Ключ положите в `.env` на рабочей машине.

---

## 2. Оверлей и порт 53

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --setup-key "$NB_KEY_ORIGIN" --hostname node01 --disable-dns
```

`--disable-dns` обязателен: агент иначе правит `/etc/resolv.conf`, а на
DNS-сервере этого быть не должно. Имя флага сверьте через `netbird up --help`
— между версиями оно переименовывалось.

**Если агент уже стоял на сервере**, установщик откажется работать
(«NetBird service is running»), а `netbird up` ответит «Already connected»
и выйдет, **не применив ни ключ, ни флаги**. Проверьте `netbird status -d`:
строки `Management`, `FQDN` и `Nameservers` покажут, куда нода подключена
и не перехвачен ли DNS. Переподключение:

```bash
netbird down && netbird up --setup-key "$NB_KEY_ORIGIN" --hostname node01 --disable-dns
```

Если осталась в старом аккаунте — сбросьте конфигурацию целиком:

```bash
systemctl stop netbird && rm -f /etc/netbird/config.json && systemctl start netbird
```

```bash
sudo sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
```

---

## 3. AdGuard Home

```bash
sudo install -d /opt/adguardhome
curl -fsSL https://raw.githubusercontent.com/dykomenko/adh-fleet/main/node/docker-compose.yml \
  | sudo tee /opt/adguardhome/docker-compose.yml > /dev/null
cd /opt/adguardhome && sudo docker compose up -d
```

Мастер установки — единственный раз за весь проект:

```bash
ssh -L 3000:127.0.0.1:3000 user@node01
```

На `http://localhost:3000`:

- **DNS-сервер** — `10.101.0.1`, порт `53`
- **Веб-интерфейс** — адрес ноды в оверлее (`netbird status`), порт `3000`
- **Логин `admin` и пароль** — пароль станет общим для всего парка

Мастер слушает все интерфейсы, поэтому туннель на `127.0.0.1` здесь работает.
После сохранения панель переедет на оверлейный адрес.

---

## 4. Фильтрация

Всё заданное здесь разъедется по репликам: списки блокировок, пользовательские
правила, апстримы, fallback-серверы, rewrites, сервисы, персональные клиенты.

Апстримы для примера: `https://dns.quad9.net/dns-query`, bootstrap `9.9.9.10`.

**Про персональных клиентов.** У одного человека на разных нодах разные адреса
(`10.101.0.5`, `10.117.0.5`). В карточке клиента AGH перечисляется несколько
идентификаторов сразу — впишите все возможные. Если клиенты кочуют между нодами
произвольно, рассмотрите ClientID через DoT или DoH.

---

## 5. Снять шаблон

Шаблон — это то, что позволяет репликам ставиться одной командой.

```bash
curl -fsSL https://raw.githubusercontent.com/dykomenko/adh-fleet/main/scripts/make-template.sh -o /tmp/mt.sh
VPN_GW=10.101.0.1 sudo -E bash /tmp/mt.sh
```

Скрипт напечатает **bcrypt-хеш пароля** — это `AGH_PASS_HASH` для установки
нод, положите его в `.env`. Сам шаблон заберите на рабочую машину
и закоммитьте:

```bash
scp node01:/tmp/AdGuardHome.yaml.tmpl node/AdGuardHome.yaml.tmpl
git add node/AdGuardHome.yaml.tmpl && git commit -m "Обновить шаблон конфига" && git push
```

Секретов в шаблоне нет: адреса и хеш заменены плейсхолдерами, подстановка
происходит на ноде. `make-template.sh` откажется писать файл, если в нём
остался хоть один bcrypt-хеш.

Переснимать нужно только при смене bind-адресов или пароля админа. Фильтры
в шаблоне роли не играют — они приезжают синхронизацией.

---

## 6. Синхронизатор

```bash
AGH_PASS='ПАРОЛЬ' sudo -E bash <(curl -fsSL https://raw.githubusercontent.com/dykomenko/adh-fleet/main/origin/setup-origin.sh)
```

Ставит adguardhome-sync, генератор списка реплик и крон. Если реплик ещё нет,
скрипт скажет об этом и завершится — поднимите первую ноду и запустите
`/opt/agh-sync/sync-now.sh`.

С этого момента добавление ноды не требует на origin ни одной правки.

---

## Эксплуатация

**Правки только здесь.** Изменение на реплике будет затёрто при следующем
прогоне.

**Синхронизация — раз в час.** Правила меняются редко, гонять чаще смысла нет.
Нужно сейчас:

```bash
/opt/agh-sync/sync-now.sh
```

Он пересоберёт список реплик и запустит прогон немедленно, показав логи.

**Обновление парка** — `scripts/fleet-update.sh` с рабочей машины,
не отсюда. На origin намеренно нет ssh-доступа к остальным нодам:
компрометация origin не должна открывать весь парк.

**Бэкап.** Реальная конфигурация существует в одном экземпляре — здесь:

```bash
tar czf agh-$(date +%F).tar.gz -C /opt/adguardhome conf
```

**Если реплика отстала:**

```bash
docker logs agh-sync
grep node07 /opt/agh-sync/sync.yaml
curl -su admin:ПАРОЛЬ http://node07:3000/control/status
```
