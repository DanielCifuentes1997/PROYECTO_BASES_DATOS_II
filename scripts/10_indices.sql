-- TurismoUQ - Script 10: indices (Entrega 3)
-- Tres consultas lentas: plan de ejecucion y medicion antes de crear el
-- indice, creacion del indice y plan y medicion despues. Al final, un caso
-- en el que el indice no ayuda.
-- Ejecutar como TURISMOUQ despues del script 09.
--
-- Como se mide cada consulta:
--   costo     = costo estimado por el optimizador (EXPLAIN PLAN).
--   lecturas  = lecturas logicas (bloques leidos de memoria) de la sesion,
--               tomadas de v$mystat antes y despues de ejecutarla muchas veces.
--   tiempo    = centesimas de segundo de todas las ejecuciones (DBMS_UTILITY.GET_TIME).
-- Las lecturas logicas son la medida mas confiable: no dependen de lo ocupado
-- que este el computador en ese momento.

SET DEFINE OFF;
SET SERVEROUTPUT ON;
SET LINESIZE 150;
SET PAGESIZE 100;
SET FEEDBACK OFF;
SET TAB OFF;

-- Borra lo que crea el script, para poder ejecutarlo de nuevo
BEGIN
  FOR i IN (SELECT index_name FROM user_indexes
            WHERE  index_name IN ('IX_RES_ESTADO_SALIDA', 'IX_PAGO_DIA',
                                  'IX_CLI_NOMBRE_MAYUS', 'IX_RES_ESTADO')) LOOP
    EXECUTE IMMEDIATE 'DROP INDEX ' || i.index_name;
  END LOOP;

  FOR t IN (SELECT table_name FROM user_tables WHERE table_name = 'MEDICION_INDICES') LOOP
    EXECUTE IMMEDIATE 'DROP TABLE medicion_indices PURGE';
  END LOOP;
END;
/

CREATE TABLE medicion_indices (
  consulta     VARCHAR2(40),
  momento      VARCHAR2(10),
  costo        NUMBER,
  acceso       VARCHAR2(60),
  ejecuciones  NUMBER,
  centesimas   NUMBER,
  lecturas     NUMBER
);

-- Lecturas logicas acumuladas por la sesion actual
CREATE OR REPLACE FUNCTION fn_lecturas_sesion RETURN NUMBER
IS
  v_lecturas NUMBER;
BEGIN
  SELECT m.value
  INTO   v_lecturas
  FROM   v$mystat m
  JOIN   v$statname n ON n.statistic# = m.statistic#
  WHERE  n.name = 'session logical reads';
  RETURN v_lecturas;
END fn_lecturas_sesion;
/

-- Guarda una medicion junto con el costo y el tipo de acceso del plan
CREATE OR REPLACE PROCEDURE sp_guardar_medicion (
  p_consulta     IN VARCHAR2,
  p_momento      IN VARCHAR2,
  p_plan         IN VARCHAR2,
  p_tabla        IN VARCHAR2,
  p_ejecuciones  IN NUMBER,
  p_centesimas   IN NUMBER,
  p_lecturas     IN NUMBER
)
IS
  v_costo   NUMBER;
  v_acceso  VARCHAR2(60);
BEGIN
  SELECT cost INTO v_costo
  FROM   plan_table
  WHERE  statement_id = p_plan AND id = 0;

  -- Como se llega a la tabla principal: recorrido completo o por un indice
  SELECT MIN(operation || ' ' || options || ' ' || object_name)
         KEEP (DENSE_RANK FIRST ORDER BY id)
  INTO   v_acceso
  FROM   plan_table
  WHERE  statement_id = p_plan
    AND  (object_name = p_tabla
          OR object_name IN (SELECT index_name FROM user_indexes WHERE table_name = p_tabla));

  INSERT INTO medicion_indices
  VALUES (p_consulta, p_momento, v_costo, v_acceso, p_ejecuciones, p_centesimas, p_lecturas);
  COMMIT;

  DBMS_OUTPUT.PUT_LINE(p_momento || ': ' || p_ejecuciones || ' ejecuciones, '
                       || p_lecturas || ' lecturas logicas ('
                       || ROUND(p_lecturas / p_ejecuciones, 1) || ' por ejecucion), '
                       || p_centesimas || ' centesimas de segundo.');
END sp_guardar_medicion;
/

DELETE FROM plan_table;
COMMIT;
BEGIN
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'RESERVA');
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'PAGO');
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'CLIENTE');
END;
/


-- =====================================================================
-- CONSULTA 1: reservas finalizadas que salieron en un mes
-- La usan la liquidacion mensual (cursores de sp_liquidar_mes) y, con estado
-- CONFIRMADA, la lista de salidas de recepcion. Hoy no hay indice sobre
-- fecha_checkout, asi que Oracle recorre las 25.000 reservas para encontrar
-- las cerca de 700 de un mes.
-- =====================================================================
PROMPT
PROMPT ===================================================================
PROMPT CONSULTA 1 - ANTES: reservas finalizadas que salieron en junio de 2025
PROMPT ===================================================================
EXPLAIN PLAN SET STATEMENT_ID = 'Q1_ANTES' FOR
SELECT COUNT(DISTINCT r.id_reserva), SUM(rh.noches * rh.valor_noche_aplicado)
FROM   reserva r
JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
WHERE  r.estado = 'FINALIZADA'
  AND  r.fecha_checkout >= DATE '2025-06-01'
  AND  r.fecha_checkout <  DATE '2025-07-01';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q1_ANTES', 'BASIC +COST +ROWS'));

-- Se ejecuta para cada uno de los 36 meses de 2024 a 2026, diez veces
DECLARE
  v_reservas  NUMBER;
  v_valor     NUMBER;
  v_lect      NUMBER := fn_lecturas_sesion;
  v_tiempo    NUMBER := DBMS_UTILITY.GET_TIME;
BEGIN
  FOR v_rep IN 1 .. 10 LOOP
    FOR v_mes IN 0 .. 35 LOOP
      SELECT COUNT(DISTINCT r.id_reserva), SUM(rh.noches * rh.valor_noche_aplicado)
      INTO   v_reservas, v_valor
      FROM   reserva r
      JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
      WHERE  r.estado = 'FINALIZADA'
        AND  r.fecha_checkout >= ADD_MONTHS(DATE '2024-01-01', v_mes)
        AND  r.fecha_checkout <  ADD_MONTHS(DATE '2024-01-01', v_mes + 1);
    END LOOP;
  END LOOP;
  sp_guardar_medicion('1. Reservas finalizadas de un mes', 'ANTES', 'Q1_ANTES', 'RESERVA', 360,
                      DBMS_UTILITY.GET_TIME - v_tiempo, fn_lecturas_sesion - v_lect);
END;
/


-- =====================================================================
-- CONSULTA 2: pagos recibidos en un dia
-- Para cuadrar la caja de un dia se compara solo la fecha, sin la hora, con
-- TRUNC(fecha_pago). Aunque hubiera un indice normal sobre fecha_pago, Oracle
-- no lo podria usar, porque la columna esta dentro de una funcion.
-- =====================================================================
PROMPT
PROMPT ===================================================================
PROMPT CONSULTA 2 - ANTES: pagos recibidos el 15 de junio de 2025
PROMPT ===================================================================
EXPLAIN PLAN SET STATEMENT_ID = 'Q2_ANTES' FOR
SELECT COUNT(*), SUM(valor)
FROM   pago
WHERE  TRUNC(fecha_pago) = DATE '2025-06-15';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q2_ANTES', 'BASIC +COST +ROWS'));

-- Se ejecuta para cada dia de 2024 y 2025
DECLARE
  v_pagos   NUMBER;
  v_valor   NUMBER;
  v_lect    NUMBER := fn_lecturas_sesion;
  v_tiempo  NUMBER := DBMS_UTILITY.GET_TIME;
BEGIN
  FOR v_dia IN 0 .. 730 LOOP
    SELECT COUNT(*), SUM(valor)
    INTO   v_pagos, v_valor
    FROM   pago
    WHERE  TRUNC(fecha_pago) = DATE '2024-01-01' + v_dia;
  END LOOP;
  sp_guardar_medicion('2. Pagos de un dia', 'ANTES', 'Q2_ANTES', 'PAGO', 731,
                      DBMS_UTILITY.GET_TIME - v_tiempo, fn_lecturas_sesion - v_lect);
END;
/


-- =====================================================================
-- CONSULTA 3: buscar un cliente por nombre sin importar mayusculas
-- En recepcion el nombre se escribe como el huesped lo dice, por eso se
-- compara con UPPER(nombre). Tampoco puede usar un indice normal.
-- =====================================================================
PROMPT
PROMPT ===================================================================
PROMPT CONSULTA 3 - ANTES: clientes que se llaman 'ana rojas' (sin importar mayusculas)
PROMPT ===================================================================
EXPLAIN PLAN SET STATEMENT_ID = 'Q3_ANTES' FOR
SELECT id_cliente, documento
FROM   cliente
WHERE  UPPER(nombre) = UPPER('ana rojas');

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q3_ANTES', 'BASIC +COST +ROWS'));

-- Se busca cada nombre distinto de la tabla, cinco veces
DECLARE
  TYPE t_nombres IS TABLE OF cliente.nombre%TYPE;
  v_nombres  t_nombres;
  v_total    NUMBER;
  v_ejec     NUMBER := 0;
  v_lect     NUMBER;
  v_tiempo   NUMBER;
BEGIN
  SELECT DISTINCT UPPER(nombre) BULK COLLECT INTO v_nombres FROM cliente;

  v_lect   := fn_lecturas_sesion;
  v_tiempo := DBMS_UTILITY.GET_TIME;
  FOR v_rep IN 1 .. 5 LOOP
    FOR i IN 1 .. v_nombres.COUNT LOOP
      SELECT COUNT(*) INTO v_total FROM cliente WHERE UPPER(nombre) = v_nombres(i);
      v_ejec := v_ejec + 1;
    END LOOP;
  END LOOP;
  sp_guardar_medicion('3. Cliente por nombre', 'ANTES', 'Q3_ANTES', 'CLIENTE', v_ejec,
                      DBMS_UTILITY.GET_TIME - v_tiempo, fn_lecturas_sesion - v_lect);
END;
/


-- =====================================================================
-- CREACION DE LOS INDICES
-- =====================================================================
PROMPT
PROMPT ===================================================================
PROMPT CREACION DE LOS INDICES
PROMPT ===================================================================

-- Compuesto. Primero la columna que se compara con igualdad (estado) y
-- despues la del rango (fecha_checkout): asi Oracle va directo a las
-- reservas de ese estado y dentro de ellas lee solo las del mes. Al final
-- va id_reserva, que es lo unico mas que la consulta necesita de RESERVA:
-- con eso el indice "cubre" la consulta y Oracle no tiene que ir a la tabla.
-- Sin id_reserva el optimizador seguia prefiriendo leer la tabla completa,
-- porque las reservas de un mes estan repartidas en casi todos los bloques
-- (se cargaron en desorden de fechas) y visitarlas una por una le salia igual
-- de caro. Sirve para la liquidacion (FINALIZADA) y para las salidas de
-- recepcion (CONFIRMADA). Va en el tablespace del historico, como la tabla.
CREATE INDEX ix_res_estado_salida ON reserva (estado, fecha_checkout, id_reserva)
  TABLESPACE ts_historico_reservas;

-- Basado en funcion: guarda ya calculado TRUNC(fecha_pago), que es
-- exactamente la expresion que usa la consulta 2.
CREATE INDEX ix_pago_dia ON pago (TRUNC(fecha_pago))
  TABLESPACE ts_historico_reservas;

-- Basado en funcion: guarda el nombre en mayusculas, como lo compara la
-- consulta 3.
CREATE INDEX ix_cli_nombre_mayus ON cliente (UPPER(nombre));

BEGIN
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'RESERVA', cascade => TRUE);
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'PAGO',    cascade => TRUE);
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'CLIENTE', cascade => TRUE);
END;
/

COLUMN index_name      FORMAT A22
COLUMN table_name      FORMAT A10
COLUMN index_type      FORMAT A28
COLUMN tablespace_name FORMAT A22
SELECT index_name, table_name, index_type, tablespace_name
FROM   user_indexes
WHERE  index_name IN ('IX_RES_ESTADO_SALIDA', 'IX_PAGO_DIA', 'IX_CLI_NOMBRE_MAYUS')
ORDER  BY index_name;


-- =====================================================================
-- LAS MISMAS TRES CONSULTAS DESPUES DE CREAR LOS INDICES
-- =====================================================================
PROMPT
PROMPT ===================================================================
PROMPT CONSULTA 1 - DESPUES
PROMPT ===================================================================
EXPLAIN PLAN SET STATEMENT_ID = 'Q1_DESPUES' FOR
SELECT COUNT(DISTINCT r.id_reserva), SUM(rh.noches * rh.valor_noche_aplicado)
FROM   reserva r
JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
WHERE  r.estado = 'FINALIZADA'
  AND  r.fecha_checkout >= DATE '2025-06-01'
  AND  r.fecha_checkout <  DATE '2025-07-01';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q1_DESPUES', 'BASIC +COST +ROWS'));

DECLARE
  v_reservas  NUMBER;
  v_valor     NUMBER;
  v_lect      NUMBER := fn_lecturas_sesion;
  v_tiempo    NUMBER := DBMS_UTILITY.GET_TIME;
BEGIN
  FOR v_rep IN 1 .. 10 LOOP
    FOR v_mes IN 0 .. 35 LOOP
      SELECT COUNT(DISTINCT r.id_reserva), SUM(rh.noches * rh.valor_noche_aplicado)
      INTO   v_reservas, v_valor
      FROM   reserva r
      JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
      WHERE  r.estado = 'FINALIZADA'
        AND  r.fecha_checkout >= ADD_MONTHS(DATE '2024-01-01', v_mes)
        AND  r.fecha_checkout <  ADD_MONTHS(DATE '2024-01-01', v_mes + 1);
    END LOOP;
  END LOOP;
  sp_guardar_medicion('1. Reservas finalizadas de un mes', 'DESPUES', 'Q1_DESPUES', 'RESERVA', 360,
                      DBMS_UTILITY.GET_TIME - v_tiempo, fn_lecturas_sesion - v_lect);
END;
/

PROMPT
PROMPT ===================================================================
PROMPT CONSULTA 2 - DESPUES
PROMPT ===================================================================
EXPLAIN PLAN SET STATEMENT_ID = 'Q2_DESPUES' FOR
SELECT COUNT(*), SUM(valor)
FROM   pago
WHERE  TRUNC(fecha_pago) = DATE '2025-06-15';

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q2_DESPUES', 'BASIC +COST +ROWS'));

DECLARE
  v_pagos   NUMBER;
  v_valor   NUMBER;
  v_lect    NUMBER := fn_lecturas_sesion;
  v_tiempo  NUMBER := DBMS_UTILITY.GET_TIME;
BEGIN
  FOR v_dia IN 0 .. 730 LOOP
    SELECT COUNT(*), SUM(valor)
    INTO   v_pagos, v_valor
    FROM   pago
    WHERE  TRUNC(fecha_pago) = DATE '2024-01-01' + v_dia;
  END LOOP;
  sp_guardar_medicion('2. Pagos de un dia', 'DESPUES', 'Q2_DESPUES', 'PAGO', 731,
                      DBMS_UTILITY.GET_TIME - v_tiempo, fn_lecturas_sesion - v_lect);
END;
/

PROMPT
PROMPT ===================================================================
PROMPT CONSULTA 3 - DESPUES
PROMPT ===================================================================
EXPLAIN PLAN SET STATEMENT_ID = 'Q3_DESPUES' FOR
SELECT id_cliente, documento
FROM   cliente
WHERE  UPPER(nombre) = UPPER('ana rojas');

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q3_DESPUES', 'BASIC +COST +ROWS'));

DECLARE
  TYPE t_nombres IS TABLE OF cliente.nombre%TYPE;
  v_nombres  t_nombres;
  v_total    NUMBER;
  v_ejec     NUMBER := 0;
  v_lect     NUMBER;
  v_tiempo   NUMBER;
BEGIN
  SELECT DISTINCT UPPER(nombre) BULK COLLECT INTO v_nombres FROM cliente;

  v_lect   := fn_lecturas_sesion;
  v_tiempo := DBMS_UTILITY.GET_TIME;
  FOR v_rep IN 1 .. 5 LOOP
    FOR i IN 1 .. v_nombres.COUNT LOOP
      SELECT COUNT(*) INTO v_total FROM cliente WHERE UPPER(nombre) = v_nombres(i);
      v_ejec := v_ejec + 1;
    END LOOP;
  END LOOP;
  sp_guardar_medicion('3. Cliente por nombre', 'DESPUES', 'Q3_DESPUES', 'CLIENTE', v_ejec,
                      DBMS_UTILITY.GET_TIME - v_tiempo, fn_lecturas_sesion - v_lect);
END;
/


-- =====================================================================
-- CASO EN QUE EL INDICE NO AYUDA
-- Se crea un indice sobre RESERVA.ESTADO para contar las reservas
-- FINALIZADAS. Pero el 84% de las reservas estan finalizadas: la condicion
-- no es selectiva. Con un indice Oracle tendria que leer casi toda la tabla
-- fila por fila, saltando entre bloques; le sale mas barato leerla completa
-- de una vez (FULL TABLE SCAN), y por eso el optimizador ignora el indice.
-- Si se le obliga a usarlo con un hint, la consulta se vuelve mas lenta.
-- =====================================================================
PROMPT
PROMPT ===================================================================
PROMPT CASO SIN MEJORA: cuantas reservas hay en cada estado
PROMPT ===================================================================
COLUMN porcentaje FORMAT 990.0
SELECT estado, COUNT(*) AS reservas,
       ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 1) AS porcentaje
FROM   reserva
GROUP  BY estado
ORDER  BY reservas DESC;

CREATE INDEX ix_res_estado ON reserva (estado) TABLESPACE ts_historico_reservas;
BEGIN
  DBMS_STATS.GATHER_TABLE_STATS(USER, 'RESERVA', cascade => TRUE,
                                method_opt => 'FOR COLUMNS estado SIZE 254');
END;
/

PROMPT
PROMPT Plan que escoge Oracle aunque exista el indice IX_RES_ESTADO:
EXPLAIN PLAN SET STATEMENT_ID = 'Q4_SIN_HINT' FOR
SELECT COUNT(*), SUM(valor_total) FROM reserva r WHERE estado = 'FINALIZADA';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q4_SIN_HINT', 'BASIC +COST +ROWS'));

PROMPT Plan obligando a Oracle a usar el indice (hint INDEX):
EXPLAIN PLAN SET STATEMENT_ID = 'Q4_CON_HINT' FOR
SELECT /*+ INDEX(r ix_res_estado) */ COUNT(*), SUM(valor_total) FROM reserva r WHERE estado = 'FINALIZADA';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q4_CON_HINT', 'BASIC +COST +ROWS'));

DECLARE
  v_total   NUMBER;
  v_valor   NUMBER;
  v_lect    NUMBER := fn_lecturas_sesion;
  v_tiempo  NUMBER := DBMS_UTILITY.GET_TIME;
BEGIN
  FOR v_rep IN 1 .. 200 LOOP
    SELECT COUNT(*), SUM(valor_total) INTO v_total, v_valor
    FROM   reserva r WHERE estado = 'FINALIZADA';
  END LOOP;
  sp_guardar_medicion('4. Reservas finalizadas (no ayuda)', 'SIN HINT', 'Q4_SIN_HINT', 'RESERVA', 200,
                      DBMS_UTILITY.GET_TIME - v_tiempo, fn_lecturas_sesion - v_lect);

  v_lect   := fn_lecturas_sesion;
  v_tiempo := DBMS_UTILITY.GET_TIME;
  FOR v_rep IN 1 .. 200 LOOP
    SELECT /*+ INDEX(r ix_res_estado) */ COUNT(*), SUM(valor_total) INTO v_total, v_valor
    FROM   reserva r WHERE estado = 'FINALIZADA';
  END LOOP;
  sp_guardar_medicion('4. Reservas finalizadas (no ayuda)', 'CON HINT', 'Q4_CON_HINT', 'RESERVA', 200,
                      DBMS_UTILITY.GET_TIME - v_tiempo, fn_lecturas_sesion - v_lect);
END;
/

-- Un indice que no se usa solo cuesta: ocupa espacio y cada INSERT o UPDATE
-- de RESERVA tiene que actualizarlo. Por eso se elimina.
DROP INDEX ix_res_estado;

PROMPT
PROMPT Otro caso sin mejora: buscar una parte del nombre con un comodin al inicio.
PROMPT El indice IX_CLI_NOMBRE_MAYUS esta ordenado desde la primera letra; con
PROMPT '%ROJAS%' no se sabe por donde empezar, asi que no se puede buscar en el.
EXPLAIN PLAN SET STATEMENT_ID = 'Q5_COMODIN' FOR
SELECT id_cliente, documento FROM cliente WHERE UPPER(nombre) LIKE '%ROJAS%';
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'Q5_COMODIN', 'BASIC +COST +ROWS'));


-- =====================================================================
-- RESUMEN
-- =====================================================================
PROMPT
PROMPT ===================================================================
PROMPT RESUMEN: antes y despues de cada indice
PROMPT ===================================================================
COLUMN consulta    FORMAT A34
COLUMN momento     FORMAT A8
COLUMN acceso      FORMAT A44
COLUMN costo       FORMAT 99990
COLUMN ejecuciones FORMAT 99990 HEADING "EJECUC."
COLUMN lect_ejec   FORMAT 999990.0 HEADING "LECT/EJEC"
COLUMN centesimas  FORMAT 999990 HEADING "CENTESIMAS"
SELECT consulta, momento, costo, acceso, ejecuciones,
       ROUND(lecturas / ejecuciones, 1) AS lect_ejec, centesimas
FROM   medicion_indices
ORDER  BY consulta, DECODE(momento, 'ANTES', 1, 'DESPUES', 2, 'SIN HINT', 3, 4);

SET FEEDBACK ON;
