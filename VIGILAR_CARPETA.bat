@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

title Robot DIAN - vigilando carpeta

echo.
echo   ============================================================
echo    Robot DIAN en marcha.
echo    Copia los XML en la carpeta  entrada
echo    Los corregidos salen en la carpeta  salida
echo    Deja esta ventana abierta. Ctrl+C para parar.
echo   ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ROBOT_DIAN.ps1" -Vigilar

echo.
pause
