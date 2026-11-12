@echo off
title TurismoUQ - Plataforma Web & Motor PL/SQL (Oracle XE 21c)
cd /d "%~dp0"
if not exist "webapp\.env" (
  echo Falta el archivo webapp\.env con la clave del usuario del portal.
  echo Copie webapp\.env.ejemplo como webapp\.env y escriba la clave.
  pause
  exit /b
)
echo ======================================================================
echo   Iniciando TurismoUQ Web Interface en http://127.0.0.1:8050
echo   El personal inicia sesion con su propio usuario de Oracle
echo ======================================================================
start http://127.0.0.1:8050
python -m uvicorn webapp.server:app --host 127.0.0.1 --port 8050
pause
