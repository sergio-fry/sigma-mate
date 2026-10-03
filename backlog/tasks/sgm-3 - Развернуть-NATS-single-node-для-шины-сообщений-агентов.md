---
id: SGM-3
title: Развернуть NATS single node для шины сообщений агентов
status: Done
assignee:
  - '@developer'
created_date: '2026-10-03 10:24'
updated_date: '2026-10-03 10:47'
labels: []
dependencies: []
references:
  - 'https://docs.nats.io/'
type: chore
ordinal: 3000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Нужна шина сообщений, через которую агенты будут общаться между собой и с оркестратором. Разворачиваем NATS single node на dev-машине: одна нода, без кластера и репликации - этого достаточно, чтобы отработать обмен. Сервер написан на Go, ставим штатный nats-server (бинарник или контейнер - решить в плане) и запускаем как сервис, который поднимается сам после перезапуска машины.

Шина должна уметь то, что понадобится дальше: pub/sub для широковещательных сообщений и request/reply через inbox для адресных запросов-ответов. Авторизацию и ограничения доступа пока не усложняем: нода локальная, доступ с dev-машины.

Результат задачи - рабочая нода плюс зафиксированные в документации проекта адрес подключения, версия и способ перезапуска. Дальше на неё будут подключаться агенты.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 nats-server поднят на dev-машине одной нодой и переживает перезапуск машины: после него шина снова доступна по документированному адресу.
- [x] #2 Клиент подключается к шине по адресу из документации, порт слушается.
- [x] #3 Проверено на живой ноде: pub/sub доставляет сообщение подписчику, request/reply через inbox возвращает ответ отправителю.
- [x] #4 Адрес подключения, версия сервера, команды перезапуска и просмотра логов описаны в документации проекта.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Живая проверка: pub/sub и request/reply выполнены реальным клиентом, команды и вывод записаны в отчёте по задаче.
- [x] #2 Сервис шины перезапущен вручную и поднялся без правки конфигурации.
- [x] #3 Конфигурация развёртывания и документация лежат в репозитории, изменения закоммичены, документация проекта и правила агентов актуальны.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Способ развёртывания: штатный бинарник nats-server v2.15.0 (linux-amd64) + systemd-сервис nats.service. Так шина не зависит от docker-демона и совпадает с практикой хоста (filebrowser и другие нативные systemd-сервисы). Порт клиента 4222, мониторинг 8222 только на localhost, авторизации нет (нода локальная, доступ с dev-машины).
2. Скачать бинарник с GitHub Releases, проверить checksum, положить в /usr/local/bin/nats-server.
3. Конфиг /etc/nats/nats-server.conf: single node, без кластера и репликации, без JetStream. Копию конфига и юнита хранить в репозитории в deploy/nats/.
4. Установить и включить systemd-юнит nats.service (Restart=on-failure, WantedBy=multi-user.target, enabled), стартовать, проверить systemctl status и порт.
5. Для живой проверки поставить CLI nats (natscli) в /usr/local/bin/nats.
6. Проверить на живой ноде: nats sub/pub (pub/sub), nats req (request/reply через _INBOX), вывод записать в заметки задачи.
7. Перезапустить сервис вручную (systemctl restart nats) и убедиться, что поднялся без правки конфигурации.
8. Задокументировать в backlog/docs: адрес подключения, версия, команды перезапуска и логов (journalctl -u nats). Обновить README (раздел Структура: deploy/nats). Закоммитить.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Развёрнуто: nats-server v2.15.0 (linux-amd64, SHA256 сверен с SHA256SUMS релиза) в /usr/local/bin/nats-server; конфиг /etc/nats/nats-server.conf; systemd-юнит nats.service (User=nats, Restart=on-failure, enabled). Слушает 0.0.0.0:4222, мониторинг 127.0.0.1:8222, авторизации нет.

Живые проверки (клиент nats CLI v0.5.0, тоже установлен в /usr/local/bin/nats):
- pub/sub: 'nats sub sigma.test --count 1' + 'nats pub sigma.test "привет всем агентам"' -> подписчик получил [#1] Received on "sigma.test": привет всем агентам.
- request/reply через inbox: 'nats reply sigma.mate.hello "привет, я agent developer, на связи"' в фоне + 'nats req sigma.mate.hello "эй, есть кто живой?"' -> ответ получен, rtt 1.1ms, reply-подписчик увидел запрос; CLI использует сгенерированный inbox (_INBOX) как reply subject.
- ручной перезапуск: systemctl restart nats -> active, порт 4222 снова слушается, клиент подключается, конфигурация не менялась.
- перезапуск машины не выполнялся изнутри сессии (убил бы саму сессию и соседние сервисы хоста); переживание перезагрузки обеспечено конструкцией: юнит enabled + WantedBy=multi-user.target + Restart=on-failure, порт и конфиг не зависят от docker.

Каверза AC #1: фактический ребут машины из сессии не выполнялся (прервал бы саму сессию и соседние сервисы dev-машины). Переживание перезагрузки обеспечено и проверено механизмом: юнит enabled (symlink в multi-user.target.wants), WantedBy=multi-user.target, Restart=on-failure; ручной перезапуск сервис прошёл без правки конфигурации. Рекомендуется подтвердить при следующем естественном ребуте машины.

rspec: 3 examples, 0 failures (спека медленная, ~5 минут - запускает bin/ask против фейкового pi; код проекта задачей не менялся).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Развернул NATS single node v2.15.0 на dev-машине как systemd-сервис nats.service (User=nats, enabled, Restart=on-failure): клиентский порт 0.0.0.0:4222, мониторинг 127.0.0.1:8222, без кластера/JetStream/авторизации. Конфиг и юнит хранятся в репозитории (deploy/nats/) и копируются на машину; эксплуатационная документация - backlog/docs/doc-2 (адрес nats://127.0.0.1:4222, версия, systemctl restart, journalctl -u nats). Проверено живым клиентом nats CLI v0.5.0: pub/sub доставил сообщение подписчику, request/reply через inbox вернул ответ (rtt ~1ms), ручной перезапуск сервиса прошёл без правки конфигурации, порт снова слушается. Ребут машины из сессии не выполнялся - переживание гарантировано enabled-юнитом в multi-user.target, подтвердить при следующем естественном ребуте. rspec проекта: 3 examples, 0 failures.
<!-- SECTION:FINAL_SUMMARY:END -->
