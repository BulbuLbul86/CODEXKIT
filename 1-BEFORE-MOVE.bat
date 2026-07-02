@echo off
setlocal
cd /d "%~dp0"
title CODEXKIT - Before Move
color 0A

echo ============================================
echo   1. SOBRAT KOMPLEKT PERED PEREEZDOM
echo ============================================
echo.
echo Zapuskay ETOT fail na TOM kompjutere, s kotorogo
echo ty seychas uezzhaesh.
echo.
echo On:
echo - obnovit nastroyki i lokalnye dannye
echo - sohranit adb, ssh, vscode, codex i privatnye faily
echo - sdelayet snimki rabochih repo dlya tochnogo pereezda
echo - po vozmozhnosti soberet codexkit-transfer.zip dlya fleshki ili pochty
echo.

:WAIT_FOR_APPS_CLOSED
powershell -NoProfile -Command "$p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in @('Code','Codex') }; if ($p) { Write-Host ''; Write-Host 'Zakroy pered sborkoy:' -ForegroundColor Yellow; $p | Sort-Object ProcessName,Id | Format-Table ProcessName,Id,MainWindowTitle -AutoSize; exit 1 }"
if errorlevel 1 (
  echo.
  echo Zakroy Codex i VS Code, potom nazhmi lyubuyu klavishu dlya povtornoj proverki.
  echo Dlya otmeny mozhno prosto zakryt eto okno.
  echo.
  pause >nul
  goto WAIT_FOR_APPS_CLOSED
)

echo Codex i VS Code zakryty. Mozhno sobirat komplekt.
echo.
set /p ARCHIVE_PASSWORD=Esli nuzhen zashchishchennyj arhiv, vvedi parol (ili prosto Enter): 
echo.

if "%ARCHIVE_PASSWORD%"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-codexkit.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-codexkit.ps1" -ArchivePassword "%ARCHIVE_PASSWORD%"
)

set "EXITCODE=%ERRORLEVEL%"
echo.
if "%EXITCODE%"=="0" (
  echo GOTOBO.
  echo.
  echo Perenosi v celom vide papku CODEXKIT
  if exist "%~dp0codexkit-transfer.zip" (
    echo ILI fayl:
    echo   %~dp0codexkit-transfer.zip
  ) else (
    echo Otdelnyj codexkit-transfer.zip ne sozdan.
    echo Eto normalno, esli nositel FAT32 i arhiv slishkom bolshoy.
    echo V etom sluchae perenosi vsyu papku CODEXKIT.
  )
  if not "%ARCHIVE_PASSWORD%"=="" (
    if exist "%~dp0codexkit-transfer-secure.rar" (
      echo   %~dp0codexkit-transfer-secure.rar
    ) else (
      echo Zashchishchennyj arhiv tozhe ne sozdan. Ispolzuy vsyu papku CODEXKIT.
    )
  )
) else (
  echo OShIBKA. Kod vykhoda: %EXITCODE%
)
echo.
pause
exit /b %EXITCODE%
