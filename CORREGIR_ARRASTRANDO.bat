@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

title Robot DIAN - corregir redondeo

if "%~1"=="" (
  echo.
  echo   ============================================================
  echo    Arrastra uno o varios archivos XML SOBRE este archivo .bat
  echo    Tambien puedes arrastrar una carpeta entera.
  echo   ============================================================
  echo.
  pause
  exit /b 1
)

echo.
echo   Corrigiendo redondeo y recalculando CUFE...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ROBOT_DIAN.ps1" %*

echo.
echo   Al lado de cada XML quedo un _corregido.xml y un _informe.txt
echo.
pause
