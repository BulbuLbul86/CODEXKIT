@echo off
setlocal
cd /d "%~dp0"
title CODEXKIT - Restore Here
color 0B

echo ============================================
echo   2. VOSSTANOVIT NA ETOM KOMPE
echo ============================================
echo.
echo Zapuskay ETOT fail na TOM kompjutere, na kotorom
echo hochesh prodolzhit rabotu pryamo seychas.
echo.
echo Eto mozhet byt:
echo - novyj komp
echo - vremennyj noutbuk
echo - etot staryj komp, kogda ty vernulsya obratno
echo.
echo Batnik snachala sam poprobuet nayti starye papki proektov.
echo Esli naydet - obnovit ih na meste.
echo Esli ne naydet - odin raz sprosit, kuda klast novye proekty.
echo.

:WAIT_FOR_APPS_CLOSED
powershell -NoProfile -Command "$p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in @('Code','Codex') }; if ($p) { Write-Host ''; Write-Host 'Zakroy pered vosstanovleniem:' -ForegroundColor Yellow; $p | Sort-Object ProcessName,Id | Format-Table ProcessName,Id,MainWindowTitle -AutoSize; exit 1 }"
if errorlevel 1 (
  echo.
  echo Zakroy Codex i VS Code, potom nazhmi lyubuyu klavishu dlya povtornoj proverki.
  echo Dlya otmeny mozhno prosto zakryt eto okno.
  echo.
  pause >nul
  goto WAIT_FOR_APPS_CLOSED
)

echo Codex i VS Code zakryty. Mozhno prodolzhat.
echo.

call :ENSURE_CODEXKIT_PAYLOAD
set "BOOTSTRAP_EXITCODE=%ERRORLEVEL%"
if not "%BOOTSTRAP_EXITCODE%"=="0" (
  echo.
  echo OShIBKA RASPAKOVKI KOMPLEKTA. Kod: %BOOTSTRAP_EXITCODE%
  echo.
  pause
  exit /b %BOOTSTRAP_EXITCODE%
)

if not exist "%~dp0restore-codexkit.ps1" (
  if exist "%~dp0CODEXKIT\2-RESTORE-HERE.bat" (
    echo Komplekt raspakovan. Zapuskayu vosstanovlenie iz nego...
    echo.
    call "%~dp0CODEXKIT\2-RESTORE-HERE.bat"
    exit /b %ERRORLEVEL%
  )

  echo Ne nayden restore-codexkit.ps1 i ne poluchilos raspakovat komplekt.
  echo Prover, chto ryadom est codexkit-transfer.zip ili papka codexkit-transfer-parts.
  echo.
  pause
  exit /b 1
)

echo 1 - tolko rabochaya sreda i glavnye programmy
echo 2 - plus pochti ves nabor programm cherez winget
echo.
set "DEFAULT_PRIVATE=%USERPROFILE%\Documents\TravelRestore"
set "DEFAULT_PROGRAMS=%SystemDrive%\TravelApps"

set /p PRIVATE_ROOT=Kuda klast privatnye faily? [Enter = %DEFAULT_PRIVATE%]: 
if "%PRIVATE_ROOT%"=="" set "PRIVATE_ROOT=%DEFAULT_PRIVATE%"

set /p PROGRAMS_ROOT=Kuda pytatsya stavit programmy? [Enter = %DEFAULT_PROGRAMS%]: 
if "%PROGRAMS_ROOT%"=="" set "PROGRAMS_ROOT=%DEFAULT_PROGRAMS%"

set "RESTORE_MODE=1"
set /p RESTORE_MODE=Vyberi rezhim [1 po umolchaniyu / 2 polnyj]: 
echo.

if "%RESTORE_MODE%"=="2" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-codexkit.ps1" -PrivateRestoreRoot "%PRIVATE_ROOT%" -ProgramsRoot "%PROGRAMS_ROOT%" -FullDesktop
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-codexkit.ps1" -PrivateRestoreRoot "%PRIVATE_ROOT%" -ProgramsRoot "%PROGRAMS_ROOT%"
)

set "RESTORE_EXITCODE=%ERRORLEVEL%"
if not "%RESTORE_EXITCODE%"=="0" (
  echo.
  echo OShIBKA VOSSTANOVLENIYa. Kod: %RESTORE_EXITCODE%
  echo.
  pause
  exit /b %RESTORE_EXITCODE%
)

echo.
echo PROVERYAYU REZULTAT...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-codexkit.ps1" -PrivateRestoreRoot "%PRIVATE_ROOT%"
set "VERIFY_EXITCODE=%ERRORLEVEL%"

echo.
if "%VERIFY_EXITCODE%"=="0" (
  echo GOTOBO. Osnovnye proverki proydeny.
) else (
  echo VOSSTANOVLENIE SDELANO, NO EShCHE EST CHTO PROVERIT. Kod: %VERIFY_EXITCODE%
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
echo Nayden perenosimyj arhiv. Raspakovyvayu shtatnymi sredstvami Windows...
set "CODEXKIT_BOOTSTRAP_BAT=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $bat=$env:CODEXKIT_BOOTSTRAP_BAT; $marker=':CODEXKIT_BOOTSTRAP_PS'; $text=[System.IO.File]::ReadAllText($bat); $idx=$text.LastIndexOf($marker); if ($idx -lt 0) { throw 'CODEXKIT bootstrap marker is missing.' }; $script=$text.Substring($idx + $marker.Length); Invoke-Expression $script"
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
    Write-Host "Extracting codexkit-transfer.zip"
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
    throw "No codexkit-transfer.zip or codexkit-transfer-part-*.zip files found."
}

foreach ($part in $parts) {
    Write-Host "Extracting $($part.Name)"
    Expand-Archive -LiteralPath $part.FullName -DestinationPath $outputRoot -Force
}
Restore-LargeFilesIfNeeded -Root $outputRoot
