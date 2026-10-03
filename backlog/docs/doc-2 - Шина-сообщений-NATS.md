---
id: doc-2
title: Шина сообщений NATS
type: guide
created_date: '2026-10-03 10:38'
updated_date: '2026-10-03 10:39'
tags:
  - nats
  - bus
  - infra
---
# Шина сообщений NATS

Единая шина для обмена сообщениями между агентами sigma-mate и оркестратором.
Развёрнута в рамках задачи SGM-3.

## Параметры подключения

- Адрес: `nats://127.0.0.1:4222` (клиентский порт слушается на `0.0.0.0:4222`)
- Авторизация: нет (нода локальная, доступ только с dev-машины)
- Сервер: `nats-server` v2.15.0 (linux-amd64, официальный бинарник), путь `/usr/local/bin/nats-server`
- Режим: single node, без кластера, репликации и JetStream
- Максимальный размер сообщения: 1MB
- Мониторинг (HTTP `/varz`, `/connz`): `http://127.0.0.1:8222` — только с самой машины

## Файлы на dev-машине

- Конфиг: `/etc/nats/nats-server.conf` (копия в репозитории: `deploy/nats/nats-server.conf`)
- Systemd-юнит: `/etc/systemd/system/nats.service` (копия в репозитории: `deploy/nats/nats.service`)
- Пользователь сервиса: системный `nats` (без shell, без данных на диск)

## Управление сервисом

```bash
systemctl status nats      # состояние
systemctl restart nats     # перезапуск вручную
systemctl stop nats        # остановка
journalctl -u nats -f      # логи в реальном времени
journalctl -u nats -n 100  # последние 100 строк логов
```

Сервис включён (`systemctl is-enabled nats` -> `enabled`), поднимается сам
после перезапуска машины (`WantedBy=multi-user.target`) и после падения
процесса (`Restart=on-failure`).

## Проверка живой ноды

Клиент: `nats` CLI v0.5.0 в `/usr/local/bin/nats` (ссылки на дистрибутивы в [README](../../deploy/nats/README.md)).

```bash
# соединение
nats --server nats://127.0.0.1:4222 server check connection

# pub/sub
nats sub sigma.test --count 1   # в одном терминале
nats pub sigma.test "привет"    # в другом

# request/reply через inbox
nats reply sigma.mate.hello "ответ"   # отвечает в своём терминале
nats req sigma.mate.hello "запрос"    # получает ответ через inbox
```

## Обновление

Файлы в `deploy/nats/` — источник истины для конфигурации на машине.
После правки конфигурации или версии сервера: скопировать файлы на место,
`systemctl daemon-reload && systemctl restart nats`, затем сверить фактическую
версию (`curl -s http://127.0.0.1:8222/varz | grep version`) и обновить этот
документ. Порядок установки с нуля — в `deploy/nats/README.md`.
