
<!-- BACKLOG.MD GUIDELINES START -->
<!-- backlog.md-instructions-version: 1.50.1 -->
<CRITICAL_INSTRUCTION>

## Backlog.md Workflow

This project uses Backlog.md for task and project management.

**For every user request in this project, run `backlog instructions overview` before answering or taking action.**

Use the overview to decide whether to search, read, create, or update Backlog tasks.

Before task lifecycle actions, read the matching detailed guide:
- `backlog instructions task-creation` before creating or splitting tasks
- `backlog instructions task-execution` before planning, changing status or assignee, adding a plan or implementation notes, or implementing task work
- `backlog instructions task-finalization` before checking acceptance criteria, writing final summaries, or moving tasks to terminal statuses

Use `backlog <command> --help` before running unfamiliar commands. Help shows options, fields, and examples.

Do not edit Backlog task, draft, document, decision, or milestone markdown files directly. Use the `backlog` CLI so metadata, relationships, and history stay consistent.

</CRITICAL_INSTRUCTION>
<!-- BACKLOG.MD GUIDELINES END -->

## Команда

Команда состоит из агентов-сотрудников. Список ведём здесь, рядом с трекером задач: сотрудник, его роль, файл с инструкциями и модель.

Сейчас сотрудник один.

- **developer** - разработчик. Выполняет задачи по проекту: берёт назначенную задачу, доводит её до терминального статуса, коммитит результат. Инструкции: `agents/developer.md`. За один запуск - одна задача. Модель: `glm/glm-5.3`, задаётся front-matter в его файле.

## Документация и правила агентов

После любой работы над проектом держим актуальными документацию проекта и правила агентов: замысел в doc-1, README, документы в `backlog/docs`, этот файл и промпты в `agents/`.

Если изменение делает написанное неправдой, текст правится в том же коммите, а не отдельной задачей. Задача не считается выполненной, пока документация и правила не приведены в соответствие с новым состоянием проекта.
