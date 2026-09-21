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

call :buscar_python
if "%PY%"=="" goto sin_python

echo.
echo   Corrigiendo redondeo y recalculando CUFE...
echo.
"%PY%" dian_robot.py %*
echo.
echo   Al lado de cada XML quedo un _corregido.xml y un _informe.txt
echo.
pause
exit /b 0

:buscar_python
set PY=
where py >nul 2>nul && set PY=py
if not "%PY%"=="" goto :eof
where python >nul 2>nul && set PY=python
goto :eof

:sin_python
echo.
echo   No encontre Python instalado en este equipo.
echo.
echo   Instalalo una sola vez desde:  https://www.python.org/downloads/
echo   IMPORTANTE: en la primera pantalla del instalador marca la casilla
echo   "Add Python to PATH" antes de darle Install.
echo.
pause
exit /b 1
