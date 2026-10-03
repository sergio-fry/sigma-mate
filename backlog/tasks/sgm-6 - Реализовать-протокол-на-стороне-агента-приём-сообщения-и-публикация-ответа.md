---
id: SGM-6
title: 'Реализовать протокол на стороне агента: приём сообщения и публикация ответа'
status: Done
assignee:
  - '@developer'
created_date: '2026-10-03 10:24'
updated_date: '2026-10-03 16:07'
labels: []
dependencies:
  - SGM-4
  - SGM-5
documentation:
  - doc-3
type: feature
ordinal: 6000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Первая половина реализации протокола (SGM-5): сторона агента. Агент принимает сообщение из своей очереди, обрабатывает его как задачу в той же сессии, что и HTTP-запросы, и публикует ответ отправителю с корреляцией на исходное сообщение. Сценарий проверки: отправитель кладёт сообщение в почтовый ящик агента и получает ответ, что работа готова, с результатом внутри.

Ошибки обработки и сообщения, которые агент не смог принять, не должны теряться молча: по протоколу отправитель получает понятный ответ или ошибку. Поведение занятого агента - по решению из SGM-5.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Сообщение, отправленное в очередь агента, приводит к обработке промпта в его сессии.
- [x] #2 Ответ публикуется в шину и связан с исходным сообщением по корреляции из протокола.
- [x] #3 Если обработка упала, отправитель получает ответ об ошибке, а не тишину.
- [x] #4 Поведение агента, когда он уже занят работой, соответствует протоколу.
- [x] #5 Состояние сессии не зависит от входа: задача, пришедшая из шины, видна в HTTP-API так же, как задача из HTTP-запроса.
<!-- AC:END -->

## Definition of Done
<!-- DOD:BEGIN -->
- [x] #1 Живая проверка на реальной шине: сообщение опубликовано клиентом шины, ответ получен в inbox отправителя; команды и вывод записаны в отчёте.
- [x] #2 Есть автотест на обработку входящего сообщения и публикацию ответа без живой шины.
- [x] #3 Изменения закоммичены, документация проекта и правила агентов актуальны.
<!-- DOD:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. lib/sigma_mate/protocol.rb: темы финальной схемы doc-3 - inbox_subject -> sigma.agent.<id>.inbox (входящие агенту), events_subject -> sigma.agent.<id>.events (ответы и события наружу); старые agent_subject и sigma.inbox.<id> убираются. Конверты sigma/1 не меняются: correlation_id = request.id уже есть.

2. lib/sigma_mate/bus.rb: подписка на sigma.agent.<id>.inbox (было - sigma.agent.<id>).

3. lib/sigma_mate/agent_protocol.rb: транспортный reply не используется - msg.reply игнорируется, каждый разобранный request обрабатывается, ответ (reply/error) публикуется событием в свой sigma.agent.<id>.events с корреляцией. Ветка 'запрос без reply-темы' уходит.

4. bin/serve: тексты (очередь inbox, ответы событиями в events с correlation_id).

5. Спеки под новую схему: protocol_spec (темы), agent_protocol_spec (ответ в events, reply-тема игнорируется), bus_spec, serve_spec e2e (отправитель подписан на events агента, публикует в inbox без reply-темы). Старые темы и _INBOX из тестов убираются.

6. README: финальная схема тем и протокол по doc-3.

7. Живая проверка на nats://127.0.0.1:4222: сервис с реальным pi и --agent-id <uuid>; nats sub sigma.agent.<uuid>.events + nats pub sigma.agent.<uuid>.inbox конверт -> событие reply с correlation_id; команды и вывод в заметки задачи.

8. Финализация: сверка AC/DoD, резюме, коммит.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Ядро готово и покрыто тестами (33 examples, 0 failures): Protocol (конверт sigma/1: parse_request с bad_request-корреляцией, reply/error-конверты, темы sigma.agent./sigma.inbox., валидация идентификатора), BusListener (подписка на sigma.agent.<id>, handler, publish с честным журналом), AgentProtocol (поток на сообщение, тот же Coordinator, ответы по статусу RunResult; unavailable для мертвой сессии, internal для прочих сбоев). Попутно найден и починен свой баг: reject!(&:alive?) удалял ЖИВЫЕ потоки (reject удаляет истинное) - заменено на delete_if { !alive? }, иначе shutdown не ждал рабочих потоков.

Ядро переведено на финальную схему doc-3 (комментарий Сергея от 15:08): Protocol.inbox_subject -> sigma.agent.<id>.inbox (подписка), Protocol.events_subject -> sigma.agent.<id>.events (ответы событием с correlation_id); старые agent_subject и sigma.inbox.<id> убраны; AgentProtocol больше не смотрит на транспортную reply-тему (msg.reply игнорируется, негативный тест есть); журнал шины без reply-адреса. README переписан под финальную схему. Юнит-спеки protocol+agent_protocol зелёные (24 examples). Попутно починена утечка одноимённых констант AGENT_ID между спек-файлами (bus_spec перетирал значение при загрузке) - agent_protocol_spec теперь на собственных константах и вычислении темы в момент вызова.

Живая проверка (DoD-1), nats://127.0.0.1:4222, реальный pi (2026-10-03):
1) bundle exec ruby bin/serve --agent-id 5717e41f-6f22-4685-afca-2336f688deda --nats-url nats://127.0.0.1:4222 --port 4655
   журнал: '[шина] подписка на очередь sigma.agent.5717e41f-6f22-4685-afca-2336f688deda.inbox поднята'
2) nats sub --count 1 sigma.agent.5717e41f-6f22-4685-afca-2336f688deda.events   (отправитель слушает events)
3) nats pub sigma.agent.5717e41f-6f22-4685-afca-2336f688deda.inbox '{...type:request, id:8568281d-96a5-4b16-b6ba-7a3abea7a2e9, from:orchestrator-test, body:{task:Ответь одним словом без инструментов: готово}}'   (без reply-темы)
4) Ответ получен в подписке отправителя через ~4с:
   {proto:sigma/1, type:reply, correlation_id:8568281d-96a5-4b16-b6ba-7a3abea7a2e9, from:5717e41f-..., to:orchestrator-test, body:{status:ok, answer:готово}}
   журнал сервиса: '[протокол] задача принята (id=8568281d-..., from=orchestrator-test)', '[протокол] ответ опубликован в sigma.agent.5717e41f-....events: {...}'.
Корреляция совпала, транспортный reply не использовался.

Финальный прогон: 55 examples, 0 failures; предупреждений о переопределении констант нет. По требованию Сергея фикстуры спеков переведены с констант (AGENT_ID/SUBJECT/HOST/... в describe) на let-хелперы и методы групп: константы describe-блоков разных файлов делят одну область видимости и перетирают друг друга при загрузке (это и было причиной падений bus_spec только в полном прогоне). Заглушки SpyPublisher/FakeCoordinator - Class.new в let, конструктор-структура сообщения - в методе bus_msg. Продакшн-код конфигурацией глобально не задаёт: всё передаётся флагами bin/serve и конструкторами (BusListener/AgentProtocol/Service).
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
author: sergei
created: 2026-10-03 15:08
---
Изменение схемы тем в doc-3 (согласовано с заказчиком): вместо reply-темы NATS ответ публикуется как событие в sigma.agent.<идентификатор>.events с correlation_id; подписка очереди переезжает с голого UUID на sigma.agent.<идентификатор>.inbox. Транспортный request/reply и _INBOX протоколом не используются. Документ уже обновлён - реализуй под него.
---
<!-- COMMENTS:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Реализована сторона агента протокола sigma/1 по финальной схеме doc-3: подписка на sigma.agent.<id>.inbox (BusListener), разбор конверта и сборка ответов (Protocol), обработка задачи через общий с HTTP Coordinator и публикация ответа событием в sigma.agent.<id>.events с correlation_id (AgentProtocol); транспортный reply NATS не используется, занятый агент вытесняется (interrupted), ошибки дают bad_request/unavailable/internal без тишины. Проверено: юнит- и e2e-тесты на фейковой шине (55 examples, 0 failures) и живой round trip на nats://127.0.0.1:4222 с реальным pi - ответ 'готово' получен в events с верной корреляцией. README и AGENTS.md приведены в соответствие. Попутно: фикстуры спеков переведены с глобальных констант на let/методы (константы describe-блоков перетирали друг друга между файлами).
<!-- SECTION:FINAL_SUMMARY:END -->
