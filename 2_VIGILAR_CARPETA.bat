@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

title Robot DIAN - vigilando carpeta

call :buscar_python
if "%PY%"=="" goto sin_python

echo.
echo   ============================================================
echo    Robot DIAN en marcha.
echo    Copia los XML en la carpeta  entrada
echo    Los corregidos salen en la carpeta  salida
echo    Deja esta ventana abierta. Ctrl+C para parar.
echo   ============================================================
echo.
"%PY%" dian_robot.py --vigilar
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
echo   IMPORTANTE: en la primera pantalla marca "Add Python to PATH".
echo.
pause
exit /b 1
