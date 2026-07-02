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
echo - pri povtornom zapuske obnovit tolko novoe i izmenennoe
echo - sohranit naydennye nastroyki, dostupy, instrumenty i privatnye faily
echo - sdelayet snimki rabochih repo dlya tochnogo pereezda
echo - soberet perenosimyj komplekt dlya fleshki ili pochty
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
  echo GOTOBO.
  echo.
  echo Perenosi papku CODEXKIT celikom.
  echo Na novom kompe zapusti tolko:
  echo   2-RESTORE-HERE.bat
  if exist "%~dp0codexkit-transfer.zip" (
    echo.
    echo Sozdan odin arhiv:
    echo   %~dp0codexkit-transfer.zip
    echo Ego ne nado otkryvat rukami: vtoroj batnik sam ego raspakuet.
  ) else (
    if exist "%~dp0codexkit-transfer-parts" (
      echo.
      echo Odin arhiv byl by slishkom bolshoy, poetomu sozdana papka chastej:
      echo   %~dp0codexkit-transfer-parts
      echo Vtoroj batnik sam soberyot ih obratno.
    )
  )
  if not "%ARCHIVE_PASSWORD%"=="" (
    if exist "%~dp0codexkit-transfer-secure*.rar" (
      echo.
      echo Sozdan zashchishchennyj arhiv ili ego chasti:
      echo   %~dp0codexkit-transfer-secure*.rar
    ) else (
      echo.
      echo Zashchishchennyj arhiv ne sozdan. Ispolzuy obychnyj komplekt CODEXKIT.
    )
  )
) else (
  echo OShIBKA. Kod vykhoda: %EXITCODE%
)
echo.
pause
exit /b %EXITCODE%
