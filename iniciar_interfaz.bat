@echo off
title TurismoUQ - Plataforma Web & Motor PL/SQL (Oracle XE 21c)
cd /d "%~dp0"
echo ======================================================================
echo   Iniciando TurismoUQ Web Interface en http://127.0.0.1:8050
echo   Conectado a Oracle XE 21c (localhost:1521/XEPDB1 - TURISMOUQ)
echo ======================================================================
start http://127.0.0.1:8050
python -m uvicorn webapp.server:app --host 127.0.0.1 --port 8050
pause

