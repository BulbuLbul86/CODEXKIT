# CODEXKIT v0.1-alpha

CODEXKIT — переносимый Windows-набор для переезда рабочей dev/Codex-среды между компьютерами. Он помогает сохранить настройки, локальные репозитории, рабочие инструменты и данные, которые обычно приходится вручную собирать по разным папкам.

Статус релиза: `v0.1-alpha`, экспериментальный публичный релиз.

## Что нового

- Безопасный режим `Safe` включён по умолчанию.
- Полный режим `Full` требует явного согласия пользователя.
- Добавлен `prepublish-check.ps1` для проверки репозитория перед публикацией.
- Добавлены `SECURITY.md`, `PRIVACY.md`, `CONTRIBUTING.md` и `CHANGELOG.md`.
- Добавлен `PlanOnly` для просмотра плана восстановления без изменений в системе.
- Transfer-архивы получают внешние `.sha256`-файлы, которые проверяются перед распаковкой.
- Репозитории с одинаковым именем получают стабильный `snapshot_id`.
- `verify-codexkit.ps1` больше не проверяет личные файлы автора.
- Добавлены минимальные Pester-тесты для публикационного контура.

## Предупреждение о безопасности

CODEXKIT может копировать чувствительные данные: SSH-ключи, токены, авторизации, Codex state, локальные конфиги, незапушенный код и пользовательские файлы.

Нельзя публиковать комплект после запуска `1-BEFORE-MOVE.bat`. Публично выкладывается только чистый шаблон репозитория.

## Проверка перед публикацией

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\prepublish-check.ps1
Invoke-Pester .\tests
```

`prepublish-check.ps1` проверяет tracked-файлы Git, обязательные публичные файлы и пустой `custom-paths.json`.

## Safe-сборка

Обычный пользовательский сценарий:

```bat
1-BEFORE-MOVE.bat
```

На вопрос:

```text
Копировать чувствительные данные, ключи, токены и авторизации? [д/Н]
```

просто нажми `Enter`. Это оставит режим `Safe`.

## Осознанный Full-режим

Чтобы сохранить полный рабочий контекст, включая чувствительные данные, ответь `д`, `да`, `y` или `yes` на вопрос о копировании секретов.

Пароль для архива не включает `Full` автоматически. Режим чувствительности выбирается отдельно.

## PlanOnly-восстановление

Перед реальным восстановлением можно посмотреть план:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\restore-codexkit.ps1 -PlanOnly
```

В этом режиме CODEXKIT ничего не копирует, не устанавливает, не распаковывает transfer-архивы и не меняет `PATH`.

## Известные ограничения

- Поддерживается Windows и Windows PowerShell 5.1+.
- Старые комплекты без `.sha256` и `snapshot_id` поддерживаются best-effort.
- Offline installers зависят от того, отдаёт ли источник пакета установщик.
- Microsoft Store и закрытые источники могут не дать полноценный offline installer.
- `custom-paths.json` — ручной механизм. Если пользователь добавил туда секреты, они будут копироваться как осознанное исключение.

## Что не публиковать

Не публикуй:

- `state/`;
- `repo-snapshots/`;
- `docs/`;
- `installers/`;
- `codexkit-state*.zip`;
- `codexkit-transfer*.zip`;
- `codexkit-transfer-parts/`;
- `codexkit-transfer-secure*.rar`;
- `*.sha256` от личного комплекта;
- `archive-hashes.txt`;
- `environment-inventory.json`;
- `machine-info.json`;
- `repo-manifest.json`;
- `state-manifest.json`;
- `tool-versions.json`;
- `vscode-extensions.txt`;
- `winget-packages.json`;
- `winget-export.log`;
- `codexkit-run-statistics.latest.*`;
- `CODEXKIT/`;
- `CODEXKIT-unpacked/`;
- личный `custom-paths.json`;
- любые ключи, токены, сертификаты и приватные конфиги.
