-- TurismoUQ - Script 00: tablespace del historico y usuario del proyecto
-- Ejecutar como SYS en la PDB XEPDB1:
--   sqlplus sys/<clave>@localhost:1521/XEPDB1 as sysdba

SET DEFINE OFF;

-- Si el tablespace ya existe se borra, para poder ejecutar el script de nuevo
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

-- Tablespace propio para el historico de reservas
CREATE TABLESPACE ts_historico_reservas
  DATAFILE 'C:\ORACLEDATABASE\ORADATA\XE\XEPDB1\ts_historico_reservas01.dbf'
  SIZE 64M
  AUTOEXTEND ON NEXT 32M MAXSIZE 2G
  EXTENT MANAGEMENT LOCAL
  SEGMENT SPACE MANAGEMENT AUTO;

-- Usuario dueno del esquema (si existe se borra con todos sus objetos)
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

-- Permisos. CREATE JOB se necesita para el refresco automatico
-- de la vista materializada de la consulta 6.
GRANT CONNECT, RESOURCE TO turismouq;

GRANT CREATE VIEW TO turismouq;

GRANT CREATE MATERIALIZED VIEW TO turismouq;

GRANT CREATE JOB TO turismouq;

-- Entrega 3: consultar las sesiones y los bloqueos durante el experimento de
-- concurrencia (quien espera a quien y sobre que objeto).
GRANT SELECT ON sys.v_$session TO turismouq;

GRANT SELECT ON sys.v_$locked_object TO turismouq;

GRANT SELECT ON sys.dba_objects TO turismouq;

PROMPT Tablespaces del proyecto:
COLUMN tablespace_name FORMAT A26
COLUMN file_name       FORMAT A62
COLUMN mb              FORMAT 999G999 HEADING "MB"
SELECT t.tablespace_name,
       d.file_name,
       ROUND(d.bytes / 1024 / 1024) AS mb
FROM   dba_tablespaces t
JOIN   dba_data_files  d ON d.tablespace_name = t.tablespace_name
WHERE  t.tablespace_name IN ('USERS', 'TS_HISTORICO_RESERVAS');
