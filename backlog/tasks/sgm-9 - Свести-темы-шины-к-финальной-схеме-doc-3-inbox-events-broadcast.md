---
id: SGM-9
title: 'Свести темы шины к финальной схеме doc-3: inbox, events, broadcast'
status: To Do
assignee:
  - developer
created_date: '2026-10-03 15:14'
labels: []
dependencies:
  - SGM-6
documentation:
  - backlog/docs/doc-3 - Протокол-общения-агентов-по-шины.md
type: chore
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Итоговая схема тем зафиксирована в doc-3: inbox и events у агента плюс broadcast. Часть кода писалась до неё: подписка очереди в SGM-4 шла на голый идентификатор, в SGM-6 завязан модуль Protocol с ящиком ответов sigma.inbox.<id>. Нужно свести код, тесты и документацию к финальному варианту без остатков старых схем.

Проверить и довести: подписка очереди на sigma.agent.<id>.inbox; ответы и события публикуются в sigma.agent.<id>.events с correlation_id; sigma.inbox.*, reply-темы NATS и _INBOX в коде и тестах не используются; README описывает финальную схему (сейчас там "subject совпадает с идентификатором"); при необходимости примеры в doc-2 и deploy/nats/README. Задача закрывается живой проверкой round trip по doc-3.

Задача - сверка и доводка после SGM-6: если SGM-6 сам сделает всё под новую схему, останется проверить и отметить.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Подписка очереди агента идёт на sigma.agent.<id>.inbox; голый идентификатор как subject нигде не используется.
- [ ] #2 Ответы и события публикуются в sigma.agent.<id>.events с correlation_id; sigma.inbox.* и reply-темы NATS из кода убраны.
- [ ] #3 README описывает финальную схему тем; расхождений между README, кодом и doc-3 нет.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Живая проверка round trip по doc-3: request в inbox, ответ в events с корреляцией; команды и вывод записаны в отчёте.
- [ ] #2 Автотесты сходятся без обращения к сети, старых тем в тестах нет.
- [ ] #3 Изменения закоммичены, документация проекта и правила агентов актуальны.
<!-- DOD:END -->
