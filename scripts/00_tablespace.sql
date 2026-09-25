-- ============================================================================
-- Proyecto Integrador TurismoUQ  |  Script 00 - Tablespace y usuario
-- Universidad del Quindio - Bases de Datos II - codigo 12338 - periodo 2026-2
-- Autor: Daniel Esteban Cifuentes Blandon
--
-- EJECUTAR COMO SYSDBA sobre la PDB XEPDB1:
--   sqlplus sys/<clave>@localhost:1521/XEPDB1 as sysdba
--   @00_tablespace.sql
--
-- ---------------------------------------------------------------------------
-- POR QUE UN TABLESPACE APARTE PARA EL HISTORICO DE RESERVAS
-- ---------------------------------------------------------------------------
-- Las 14 tablas no se comportan igual. Se separan en dos grupos:
--
--   CATALOGO (queda en USERS): MUNICIPIO, TIPO_ALOJAMIENTO, ALOJAMIENTO,
--   HABITACION, TEMPORADA, TARIFA, CLIENTE, SERVICIO, USUARIO_SISTEMA.
--   Son pocas filas, cambian poco y se consultan todo el tiempo.
--
--   HISTORICO (queda en TS_HISTORICO_RESERVAS): RESERVA, RESERVA_HABITACION,
--   RESERVA_SERVICIO, PAGO, RESENA. Son el 99% de las filas, solo crecen,
--   y una vez cerrada la reserva ya nadie las modifica.
--
-- Separarlos sirve para cuatro cosas concretas:
--
--   1. Respaldo. El catalogo se respalda completo todos los dias porque es
--      pequeno. El historico se respalda por incrementales: copiar 25.000
--      reservas que no cambiaron no tiene sentido.
--
--   2. Mantenimiento independiente. Se puede poner el tablespace del
--      historico en READ ONLY por temporadas viejas, o comprimirlo, sin
--      tocar las tablas que la aplicacion esta usando en vivo.
--
--   3. Aislamiento de espacio. Si el historico se desborda, el AUTOEXTEND
--      se queda sin MAXSIZE en ESE datafile y no tumba las tablas de
--      catalogo, que viven en otro archivo.
--
--   4. Recuperacion mas corta. Un RECOVER sobre un tablespace de catalogo
--      de pocos MB tarda segundos; no hay que esperar a que se restaure
--      todo el historico para volver a operar.
-- ============================================================================
SET DEFINE OFF;

-- ---------------------------------------------------------------------------
-- 1. Tablespace del historico de reservas
--    SEGMENT SPACE MANAGEMENT AUTO -> Oracle administra las listas de bloques
--    libres con bitmaps, que es lo adecuado para una tabla que solo recibe
--    INSERT masivos.
-- ---------------------------------------------------------------------------
DECLARE
  v_existe NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_existe
  FROM   dba_tablespaces
  WHERE  tablespace_name = 'TS_HISTORICO_RESERVAS';

  IF v_existe = 1 THEN
    EXECUTE IMMEDIATE 'DROP TABLESPACE ts_historico_reservas
                       INCLUDING CONTENTS AND DATAFILES';
    DBMS_OUTPUT.PUT_LINE('Tablespace anterior eliminado.');
  END IF;
END;
/

CREATE TABLESPACE ts_historico_reservas
  DATAFILE 'C:\ORACLEDATABASE\ORADATA\XE\XEPDB1\ts_historico_reservas01.dbf'
  SIZE 64M
  AUTOEXTEND ON NEXT 32M MAXSIZE 2G
  EXTENT MANAGEMENT LOCAL
  SEGMENT SPACE MANAGEMENT AUTO;

-- ---------------------------------------------------------------------------
-- 2. Usuario dueno del esquema
-- ---------------------------------------------------------------------------
DECLARE
  v_existe NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_existe FROM dba_users WHERE username = 'TURISMOUQ';
  IF v_existe = 1 THEN
    EXECUTE IMMEDIATE 'DROP USER turismouq CASCADE';
  END IF;
END;
/

CREATE USER turismouq IDENTIFIED BY "Daniel.sharond15"
  DEFAULT TABLESPACE users
  QUOTA UNLIMITED ON users
  QUOTA UNLIMITED ON ts_historico_reservas;

-- CONNECT permite iniciar sesion; RESOURCE permite crear tablas, indices y
-- codigo PL/SQL dentro del propio esquema.
GRANT CONNECT, RESOURCE TO turismouq;

-- Para las vistas de analisis.
GRANT CREATE VIEW TO turismouq;

-- Para la vista materializada de ocupacion mensual (consulta 6).
GRANT CREATE MATERIALIZED VIEW TO turismouq;

-- El refresco automatico (START WITH ... NEXT ...) Oracle lo implementa como
-- un job del scheduler. Sin este privilegio el CREATE MATERIALIZED VIEW falla
-- con ORA-01031 privilegios insuficientes.
GRANT CREATE JOB TO turismouq;

PROMPT
PROMPT ---------------------------------------------------------------
PROMPT  Tablespace y usuario listos
PROMPT ---------------------------------------------------------------
COLUMN tablespace_name FORMAT A26
COLUMN file_name       FORMAT A62
COLUMN mb              FORMAT 999G999 HEADING "MB"
SELECT t.tablespace_name,
       d.file_name,
       ROUND(d.bytes / 1024 / 1024) AS mb
FROM   dba_tablespaces t
JOIN   dba_data_files  d ON d.tablespace_name = t.tablespace_name
WHERE  t.tablespace_name IN ('USERS', 'TS_HISTORICO_RESERVAS');
