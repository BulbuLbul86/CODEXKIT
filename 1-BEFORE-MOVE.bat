@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title CODEXKIT - сбор комплекта
color 0A

echo ============================================
echo   1. СОБРАТЬ КОМПЛЕКТ ПЕРЕД ПЕРЕЕЗДОМ
echo ============================================
echo.
echo Запускай этот файл на том компьютере, с которого
echo сейчас переезжаешь.
echo.
echo Он:
echo - обновит настройки и локальные данные
echo - при повторном запуске добавит только новое и изменённое
echo - сохранит найденные настройки, доступы, инструменты и личные файлы
echo - сделает снимки рабочих репозиториев для точного переезда
echo - соберёт переносимый комплект для флешки или почты
echo.

:WAIT_FOR_APPS_CLOSED
powershell -NoProfile -Command "$p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in @('Code','Codex') }; if ($p) { Write-Host ''; Write-Host 'Перед сборкой закрой:' -ForegroundColor Yellow; $p | Sort-Object ProcessName,Id | Format-Table ProcessName,Id,MainWindowTitle -AutoSize; exit 1 }"
if errorlevel 1 (
  echo.
  echo Закрой Codex и VS Code, потом нажми любую клавишу для повторной проверки.
  echo Для отмены можно просто закрыть это окно.
  echo.
  pause >nul
  goto WAIT_FOR_APPS_CLOSED
)

echo Codex и VS Code закрыты. Можно собирать комплект.
echo.
set /p ARCHIVE_PASSWORD=Если нужен защищённый архив, введи пароль или просто нажми Enter:
echo.
set "REFRESH_MODE=Auto"
if not "%CODEXKIT_REFRESH_MODE%"=="" set "REFRESH_MODE=%CODEXKIT_REFRESH_MODE%"

if "%ARCHIVE_PASSWORD%"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-codexkit.ps1" -RefreshMode "%REFRESH_MODE%"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-codexkit.ps1" -ArchivePassword "%ARCHIVE_PASSWORD%" -RefreshMode "%REFRESH_MODE%"
)

set "EXITCODE=%ERRORLEVEL%"
echo.
if "%EXITCODE%"=="0" (
  echo ГОТОВО.
  echo.
  echo Переноси всю флешку или всю папку с этими файлами.
  echo На новом компьютере запусти только:
  echo   2-RESTORE-HERE.bat
  if exist "%~dp0codexkit-transfer.zip" (
    echo.
    echo Создан один архив:
    echo   %~dp0codexkit-transfer.zip
    echo Его не нужно открывать руками: второй батник сам его распакует.
  ) else (
    if exist "%~dp0codexkit-transfer-parts" (
      echo.
      echo Один архив был бы слишком большим, поэтому создана папка частей:
      echo   %~dp0codexkit-transfer-parts
      echo Второй батник сам соберёт их обратно.
    )
  )
  if not "%ARCHIVE_PASSWORD%"=="" (
    if exist "%~dp0codexkit-transfer-secure*.rar" (
      echo.
      echo Создан защищённый архив или его части:
      echo   %~dp0codexkit-transfer-secure*.rar
    ) else (
      echo.
      echo Защищённый архив не создан. Используй обычный комплект CODEXKIT.
    )
  )
) else (
  echo ОШИБКА. Код выхода: %EXITCODE%
)
echo.
pause
exit /b %EXITCODE%
