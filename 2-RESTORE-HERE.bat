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
