# deploy/nats — шина сообщений NATS (single node)

Развёртывание NATS-шины для обмена сообщениями агентов sigma-mate.
Эксплуатационные подробности (адрес, версия, управление сервисом) —
в документе `backlog/docs/doc-2 - Шина-сообщений-NATS.md`.

- `nats-server.conf` — конфиг сервера, на машине лежит в `/etc/nats/nats-server.conf`
- `nats.service` — systemd-юнит, на машине лежит в `/etc/systemd/system/nats.service`

## Установка с нуля (dev-машина, Ubuntu 24.04, root)

1. Пользователь сервиса:

```bash
useradd --system --no-create-home --shell /usr/sbin/nologin nats
```

2. Бинарник `nats-server` — официальный релиз (актуальная версия — в doc-2):
   <https://github.com/nats-io/nats-server/releases>. Проверить SHA256
   из `SHA256SUMS` релиза, распаковать, положить в `/usr/local/bin/nats-server`.

3. Конфиг:

```bash
mkdir -p /etc/nats
cp nats-server.conf /etc/nats/nats-server.conf
```

4. Сервис:

```bash
cp nats.service /etc/systemd/system/nats.service
systemctl daemon-reload
systemctl enable --now nats
```

5. Проверка: порт 4222 слушается, `nats --server nats://127.0.0.1:4222 server check connection` возвращает OK.

## Обновление версии сервера

Скачать новый релиз, заменить `/usr/local/bin/nats-server`,
`systemctl restart nats`, сверить версию в `curl -s http://127.0.0.1:8222/varz`,
обновить doc-2.

## Изменение конфигурации

Правится в этом репозитории (`nats-server.conf`), копируется на машину,
`systemctl restart nats`. Конфиг на машине не редактируется напрямую.
