@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title CODEXKIT - восстановление
color 0B

echo ============================================
echo   2. ВОССТАНОВИТЬ НА ЭТОМ КОМПЬЮТЕРЕ
echo ============================================
echo.
echo Запускай этот файл на том компьютере, где
echo хочешь продолжить работу прямо сейчас.
echo.
echo Это может быть:
echo - новый компьютер
echo - временный ноутбук
echo - этот старый компьютер, когда ты вернулся обратно
echo.
echo Файл сначала сам попробует найти старые папки проектов.
echo Если найдёт — обновит их на месте.
echo Если не найдёт — один раз спросит, куда сохранять новые проекты.
echo.

:WAIT_FOR_APPS_CLOSED
powershell -NoProfile -Command "$p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in @('Code','Codex') }; if ($p) { Write-Host ''; Write-Host 'Перед восстановлением закрой:' -ForegroundColor Yellow; $p | Sort-Object ProcessName,Id | Format-Table ProcessName,Id,MainWindowTitle -AutoSize; exit 1 }"
if errorlevel 1 (
  echo.
  echo Закрой Codex и VS Code, потом нажми любую клавишу для повторной проверки.
  echo Для отмены можно просто закрыть это окно.
  echo.
  pause >nul
  goto WAIT_FOR_APPS_CLOSED
)

echo Codex и VS Code закрыты. Можно продолжать.
echo.

call :ENSURE_CODEXKIT_PAYLOAD
set "BOOTSTRAP_EXITCODE=%ERRORLEVEL%"
if not "%BOOTSTRAP_EXITCODE%"=="0" (
  echo.
  echo ОШИБКА РАСПАКОВКИ КОМПЛЕКТА. Код: %BOOTSTRAP_EXITCODE%
  echo.
  pause
  exit /b %BOOTSTRAP_EXITCODE%
)

if not exist "%~dp0restore-codexkit.ps1" (
  if exist "%~dp0CODEXKIT\2-RESTORE-HERE.bat" (
    echo Комплект распакован. Запускаю восстановление из него...
    echo.
    call "%~dp0CODEXKIT\2-RESTORE-HERE.bat"
    exit /b %ERRORLEVEL%
  )

  echo Не найден restore-codexkit.ps1 и не получилось распаковать комплект.
  echo Проверь, что рядом есть codexkit-transfer.zip или папка codexkit-transfer-parts.
  echo.
  pause
  exit /b 1
)

echo Восстанавливаю рабочую среду, проекты и настройки.
echo Программы будут предложены по одной: с коротким описанием
echo и подсказкой, для каких задач они могут понадобиться.
echo Полный список программ со старого ПК сохранится как справка.
echo.
set "DEFAULT_PRIVATE=%USERPROFILE%\Documents\TravelRestore"
set "DEFAULT_PROGRAMS=%SystemDrive%\TravelApps"

set /p PRIVATE_ROOT=Куда сохранять личные файлы? [Enter = %DEFAULT_PRIVATE%]:
if "%PRIVATE_ROOT%"=="" set "PRIVATE_ROOT=%DEFAULT_PRIVATE%"

set /p PROGRAMS_ROOT=Куда устанавливать программы? [Enter = %DEFAULT_PROGRAMS%]:
if "%PROGRAMS_ROOT%"=="" set "PROGRAMS_ROOT=%DEFAULT_PROGRAMS%"

echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-codexkit.ps1" -PrivateRestoreRoot "%PRIVATE_ROOT%" -ProgramsRoot "%PROGRAMS_ROOT%"

set "RESTORE_EXITCODE=%ERRORLEVEL%"
if not "%RESTORE_EXITCODE%"=="0" (
  echo.
  echo ОШИБКА ВОССТАНОВЛЕНИЯ. Код: %RESTORE_EXITCODE%
  echo.
  pause
  exit /b %RESTORE_EXITCODE%
)

echo.
echo ПРОВЕРЯЮ РЕЗУЛЬТАТ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-codexkit.ps1" -PrivateRestoreRoot "%PRIVATE_ROOT%"
set "VERIFY_EXITCODE=%ERRORLEVEL%"

echo.
if "%VERIFY_EXITCODE%"=="0" (
  echo ГОТОВО. Основные проверки пройдены.
) else (
  echo ВОССТАНОВЛЕНИЕ ВЫПОЛНЕНО, НО ЕСТЬ ЧТО ПРОВЕРИТЬ. Код: %VERIFY_EXITCODE%
)
echo.
pause
exit /b %VERIFY_EXITCODE%

:ENSURE_CODEXKIT_PAYLOAD
if exist "%~dp0restore-codexkit.ps1" (
  if exist "%~dp0state" exit /b 0
  if exist "%~dp0codexkit-state.zip" exit /b 0
)

if exist "%~dp0codexkit-transfer.zip" goto UNPACK_CODEXKIT_PAYLOAD
if exist "%~dp0codexkit-transfer-parts" goto UNPACK_CODEXKIT_PAYLOAD
dir /b "%~dp0codexkit-transfer-part-*.zip" >nul 2>nul
if not errorlevel 1 goto UNPACK_CODEXKIT_PAYLOAD
exit /b 0

:UNPACK_CODEXKIT_PAYLOAD
echo Найден переносимый архив. Распаковываю штатными средствами Windows...
set "CODEXKIT_BOOTSTRAP_BAT=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $bat=$env:CODEXKIT_BOOTSTRAP_BAT; $marker=':CODEXKIT_BOOTSTRAP_PS'; $text=[System.IO.File]::ReadAllText($bat,[System.Text.Encoding]::UTF8); $idx=$text.LastIndexOf($marker); if ($idx -lt 0) { throw 'Не найден встроенный блок распаковки CODEXKIT.' }; $script=$text.Substring($idx + $marker.Length); Invoke-Expression $script"
exit /b %ERRORLEVEL%

:CODEXKIT_BOOTSTRAP_PS
$ErrorActionPreference = "Stop"

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Restore-LargeFilesIfNeeded {
    param([string]$Root)

    $largeFilesManifestPath = Join-Path $Root "codexkit-large-files\manifest.json"
    if (-not (Test-Path -LiteralPath $largeFilesManifestPath)) {
        return
    }

    $manifest = Get-Content -LiteralPath $largeFilesManifestPath -Raw | ConvertFrom-Json
    foreach ($file in @($manifest.files)) {
        $destination = Join-Path $Root (([string]$file.path) -replace '/', '\')
        Ensure-Dir -Path (Split-Path -Parent $destination)

        $outputStream = [System.IO.File]::Open($destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try {
            foreach ($chunk in @($file.chunks)) {
                $chunkPath = Join-Path $Root (([string]$chunk) -replace '/', '\')
                $inputStream = [System.IO.File]::OpenRead($chunkPath)
                try {
                    $inputStream.CopyTo($outputStream)
                } finally {
                    $inputStream.Dispose()
                }
            }
        } finally {
            $outputStream.Dispose()
        }
    }

    Remove-Item -LiteralPath (Join-Path $Root "codexkit-large-files") -Recurse -Force
}

$root = Split-Path -Parent $env:CODEXKIT_BOOTSTRAP_BAT
$hasRestoreScript = Test-Path -LiteralPath (Join-Path $root "restore-codexkit.ps1")
$outputRoot = if ($hasRestoreScript) { $root } else { Join-Path $root "CODEXKIT" }
Ensure-Dir -Path $outputRoot

$singleArchive = Join-Path $root "codexkit-transfer.zip"
$partsRoot = Join-Path $root "codexkit-transfer-parts"

if (Test-Path -LiteralPath $singleArchive) {
    Write-Host "Распаковываю codexkit-transfer.zip"
    Expand-Archive -LiteralPath $singleArchive -DestinationPath $outputRoot -Force
    Restore-LargeFilesIfNeeded -Root $outputRoot
    return
}

$parts = @()
if (Test-Path -LiteralPath $partsRoot) {
    $parts = @(Get-ChildItem -LiteralPath $partsRoot -Filter "codexkit-transfer-part-*.zip" -File -ErrorAction SilentlyContinue | Sort-Object Name)
} else {
    $parts = @(Get-ChildItem -LiteralPath $root -Filter "codexkit-transfer-part-*.zip" -File -ErrorAction SilentlyContinue | Sort-Object Name)
}

if ($parts.Count -eq 0) {
    throw "Не найден codexkit-transfer.zip или файлы codexkit-transfer-part-*.zip."
}

foreach ($part in $parts) {
    Write-Host "Распаковываю $($part.Name)"
    Expand-Archive -LiteralPath $part.FullName -DestinationPath $outputRoot -Force
}
Restore-LargeFilesIfNeeded -Root $outputRoot
