-- TurismoUQ - Script 07: pruebas de la Entrega 2
-- Ejecutar como TURISMOUQ despues de los scripts 05 y 06

SET DEFINE OFF;
SET SERVEROUTPUT ON;
SET LINESIZE 140;
SET PAGESIZE 60;
SET FEEDBACK OFF;
SET TAB OFF;
ALTER SESSION SET NLS_DATE_FORMAT = 'DD/MM/YYYY';

-- Prueba 1: fn_valor_estadia

PROMPT
PROMPT Prueba 1.1: funcion contra los valores guardados por la carga, en todas las estadias
SET TIMING ON;
SELECT COUNT(*)                                               AS estadias_comparadas,
       SUM(CASE WHEN guardado =  calculado THEN 1 ELSE 0 END) AS coinciden,
       SUM(CASE WHEN guardado <> calculado THEN 1 ELSE 0 END) AS diferentes
FROM (
  SELECT rh.id_reserva,
         rh.id_habitacion,
         SUM(rh.noches * rh.valor_noche_aplicado) AS guardado,
         pkg_turismouq.fn_valor_estadia(rh.id_habitacion,
                                        MAX(r.fecha_checkin),
                                        MAX(r.fecha_checkout)) AS calculado
  FROM   reserva_habitacion rh
  JOIN   reserva r ON r.id_reserva = rh.id_reserva
  GROUP  BY rh.id_reserva, rh.id_habitacion
);
SET TIMING OFF;

PROMPT
PROMPT Prueba 1.2: habitacion 1 del 30/12/2025 al 02/01/2026 (cruza dos temporadas)
COLUMN temporada FORMAT A20
SELECT t.nombre       AS temporada,
       tf.valor_noche AS tarifa_noche,
       LEAST(DATE '2026-01-02' - 1, t.fecha_fin)
         - GREATEST(DATE '2025-12-30', t.fecha_inicio) + 1 AS noches
FROM   temporada t
JOIN   tarifa tf ON tf.id_temporada  = t.id_temporada
                AND tf.id_habitacion = 1
WHERE  t.fecha_inicio <= DATE '2026-01-01'
  AND  t.fecha_fin    >= DATE '2025-12-30'
ORDER  BY t.fecha_inicio;

SELECT pkg_turismouq.fn_valor_estadia(
         p_id_habitacion => 1,
         p_fecha_in      => DATE '2025-12-30',
         p_fecha_out     => DATE '2026-01-02') AS valor_estadia
FROM   dual;

PROMPT
PROMPT Prueba 1.3: errores que debe lanzar la funcion
BEGIN
  DBMS_OUTPUT.PUT_LINE('a) Salida el mismo dia de la entrada:');
  DBMS_OUTPUT.PUT_LINE(pkg_turismouq.fn_valor_estadia(1, DATE '2025-06-10', DATE '2025-06-10'));
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/
BEGIN
  DBMS_OUTPUT.PUT_LINE('b) Habitacion que no existe:');
  DBMS_OUTPUT.PUT_LINE(pkg_turismouq.fn_valor_estadia(9999, DATE '2025-06-10', DATE '2025-06-12'));
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/
BEGIN
  DBMS_OUTPUT.PUT_LINE('c) Fechas sin temporada definida (marzo de 2030):');
  DBMS_OUTPUT.PUT_LINE(pkg_turismouq.fn_valor_estadia(1, DATE '2030-03-01', DATE '2030-03-04'));
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 1.4: despues de un error la funcion sigue respondiendo
SELECT pkg_turismouq.fn_valor_estadia(1, DATE '2025-06-10', DATE '2025-06-12') AS llamada_normal
FROM   dual;


-- Prueba 2: sp_crear_reserva
-- Se usan fechas de 2027, donde no hay reservas cargadas. Primero se borran
-- las reservas de prueba que haya dejado una ejecucion anterior de este script.
DELETE FROM pago
WHERE  id_reserva IN (SELECT id_reserva FROM reserva WHERE fecha_checkin >= DATE '2027-01-01');
DELETE FROM reserva_servicio
WHERE  id_reserva IN (SELECT id_reserva FROM reserva WHERE fecha_checkin >= DATE '2027-01-01');
DELETE FROM reserva_habitacion
WHERE  id_reserva IN (SELECT id_reserva FROM reserva WHERE fecha_checkin >= DATE '2027-01-01');
DELETE FROM reserva
WHERE  fecha_checkin >= DATE '2027-01-01';
COMMIT;

PROMPT
PROMPT Prueba 2.1: reserva valida, habitacion 2 (doble) del 19/03/2027 al 23/03/2027
PROMPT             para 2 personas. Cruza de temporada baja a Semana Santa.
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 1,
    p_id_habitacion => 2,
    p_fecha_in      => DATE '2027-03-19',
    p_fecha_out     => DATE '2027-03-23',
    p_num_huespedes => 2,
    p_id_reserva    => v_id);
END;
/

PROMPT
PROMPT Prueba 2.2: la misma habitacion del 21/03/2027 al 24/03/2027 (se cruza con la anterior)
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 2,
    p_id_habitacion => 2,
    p_fecha_in      => DATE '2027-03-21',
    p_fecha_out     => DATE '2027-03-24',
    p_num_huespedes => 2,
    p_id_reserva    => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 2.3: la misma habitacion del 15/03/2027 al 19/03/2027. Sale el mismo dia
PROMPT             que entra la reserva 2.1, eso no es cruce y se debe permitir.
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 3,
    p_id_habitacion => 2,
    p_fecha_in      => DATE '2027-03-15',
    p_fecha_out     => DATE '2027-03-19',
    p_num_huespedes => 1,
    p_id_reserva    => v_id);
END;
/

PROMPT
PROMPT Prueba 2.4: 3 personas en la habitacion 2, que es doble
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 4,
    p_id_habitacion => 2,
    p_fecha_in      => DATE '2027-05-01',
    p_fecha_out     => DATE '2027-05-03',
    p_num_huespedes => 3,
    p_id_reserva    => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 2.5: salida el mismo dia de la entrada
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 4,
    p_id_habitacion => 2,
    p_fecha_in      => DATE '2027-05-01',
    p_fecha_out     => DATE '2027-05-01',
    p_num_huespedes => 2,
    p_id_reserva    => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 2.6: fecha de entrada en el pasado
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 4,
    p_id_habitacion => 2,
    p_fecha_in      => DATE '2025-05-01',
    p_fecha_out     => DATE '2025-05-03',
    p_num_huespedes => 2,
    p_id_reserva    => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 2.7: cliente que no existe
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 99999,
    p_id_habitacion => 2,
    p_fecha_in      => DATE '2027-05-01',
    p_fecha_out     => DATE '2027-05-03',
    p_num_huespedes => 2,
    p_id_reserva    => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 2.8: habitacion que no existe
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 4,
    p_id_habitacion => 9999,
    p_fecha_in      => DATE '2027-05-01',
    p_fecha_out     => DATE '2027-05-03',
    p_num_huespedes => 2,
    p_id_reserva    => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 2.9: habitacion 25, que esta en mantenimiento
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => 4,
    p_id_habitacion => 25,
    p_fecha_in      => DATE '2027-05-01',
    p_fecha_out     => DATE '2027-05-03',
    p_num_huespedes => 2,
    p_id_reserva    => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 2.10: reservas que quedaron guardadas y su detalle por temporada
COLUMN estado    FORMAT A11
COLUMN temporada FORMAT A20
SELECT id_reserva, id_cliente, fecha_checkin, fecha_checkout,
       num_huespedes, estado, valor_total
FROM   reserva
WHERE  fecha_checkin >= DATE '2027-01-01'
ORDER  BY id_reserva;

SELECT rh.id_reserva,
       rh.id_habitacion,
       t.nombre AS temporada,
       rh.noches,
       rh.valor_noche_aplicado
FROM   reserva_habitacion rh
JOIN   temporada t ON t.id_temporada = rh.id_temporada
WHERE  rh.id_reserva IN (SELECT id_reserva FROM reserva
                         WHERE  fecha_checkin >= DATE '2027-01-01')
ORDER  BY rh.id_reserva, t.fecha_inicio;


-- Prueba 3: sp_liquidar_mes
-- Se liquida junio de 2025. Primero se borra la liquidacion de ese mes que
-- haya dejado una ejecucion anterior de este script.
DELETE FROM liquidacion_mensual WHERE periodo = DATE '2025-06-01';
COMMIT;

PROMPT
PROMPT Prueba 3.1: liquidar junio de 2025 con la comision por defecto (12%)
BEGIN
  pkg_turismouq.sp_liquidar_mes(p_periodo => DATE '2025-06-01');
END;
/

PROMPT
PROMPT Prueba 3.2: los 10 alojamientos con mayor valor a pagar en junio de 2025
COLUMN alojamiento         FORMAT A24
COLUMN ingreso_alojamiento FORMAT 999G999G999 HEADING "ING_ALOJAMIENTO"
COLUMN ingreso_servicios   FORMAT 999G999G999 HEADING "ING_SERVICIOS"
COLUMN valor_comision      FORMAT 999G999G999 HEADING "COMISION"
COLUMN valor_a_pagar       FORMAT 999G999G999 HEADING "A_PAGAR"
SELECT *
FROM  (SELECT a.nombre AS alojamiento,
              l.reservas,
              l.noches_vendidas,
              l.ingreso_alojamiento,
              l.ingreso_servicios,
              l.valor_comision,
              l.valor_a_pagar
       FROM   liquidacion_mensual l
       JOIN   alojamiento a ON a.id_alojamiento = l.id_alojamiento
       WHERE  l.periodo = DATE '2025-06-01'
       ORDER  BY l.valor_a_pagar DESC)
WHERE  ROWNUM <= 10;

PROMPT
PROMPT Prueba 3.3: los ingresos de la liquidacion contra un calculo directo sobre las reservas
COLUMN segun_liquidacion FORMAT 999G999G999G999
COLUMN calculo_directo   FORMAT 999G999G999G999
SELECT 'Alojamiento' AS concepto,
       (SELECT SUM(ingreso_alojamiento) FROM liquidacion_mensual
        WHERE  periodo = DATE '2025-06-01') AS segun_liquidacion,
       (SELECT SUM(rh.noches * rh.valor_noche_aplicado)
        FROM   reserva r
        JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
        WHERE  r.estado = 'FINALIZADA'
          AND  r.fecha_checkout >= DATE '2025-06-01'
          AND  r.fecha_checkout <  DATE '2025-07-01') AS calculo_directo
FROM   dual
UNION ALL
SELECT 'Servicios',
       (SELECT SUM(ingreso_servicios) FROM liquidacion_mensual
        WHERE  periodo = DATE '2025-06-01'),
       (SELECT SUM(rs.valor_total)
        FROM   reserva r
        JOIN   reserva_servicio rs ON rs.id_reserva = r.id_reserva
        WHERE  r.estado = 'FINALIZADA'
          AND  r.fecha_checkout >= DATE '2025-06-01'
          AND  r.fecha_checkout <  DATE '2025-07-01')
FROM   dual;

PROMPT
PROMPT Prueba 3.4: el detalle reserva por reserva de cada alojamiento suma exactamente su total
PROMPT             (alojamientos_que_no_cuadran debe dar 0)
SELECT COUNT(*) AS alojamientos_liquidados,
       SUM(CASE WHEN l.reservas            <> d.reservas
                  OR l.ingreso_alojamiento <> d.alojamiento
                  OR l.ingreso_servicios   <> d.servicios
                THEN 1 ELSE 0 END) AS alojamientos_que_no_cuadran,
       SUM(d.reservas) AS reservas_en_el_detalle
FROM   liquidacion_mensual l
JOIN  (SELECT id_alojamiento, periodo, COUNT(*) AS reservas,
              SUM(valor_alojamiento) AS alojamiento, SUM(valor_servicios) AS servicios
       FROM   liquidacion_detalle
       GROUP  BY id_alojamiento, periodo) d
       ON d.id_alojamiento = l.id_alojamiento AND d.periodo = l.periodo
WHERE  l.periodo = DATE '2025-06-01';

PROMPT
PROMPT Prueba 3.5: reporte de la liquidacion de junio de 2025 del alojamiento que mas recibe,
PROMPT             reserva por reserva
DECLARE
  v_id_alojamiento liquidacion_mensual.id_alojamiento%TYPE;
BEGIN
  SELECT id_alojamiento
  INTO   v_id_alojamiento
  FROM  (SELECT id_alojamiento FROM liquidacion_mensual
         WHERE  periodo = DATE '2025-06-01'
         ORDER  BY valor_a_pagar DESC)
  WHERE  ROWNUM = 1;

  pkg_turismouq.sp_reporte_liquidacion(p_periodo        => DATE '2025-06-01',
                                       p_id_alojamiento => v_id_alojamiento);
END;
/

PROMPT
PROMPT Prueba 3.6: reporte de un mes que no esta liquidado
BEGIN
  pkg_turismouq.sp_reporte_liquidacion(p_periodo => DATE '2025-02-01');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 3.7: volver a liquidar junio de 2025
BEGIN
  pkg_turismouq.sp_liquidar_mes(p_periodo => DATE '2025-06-01');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 3.8: liquidar el mes actual, que todavia no termina
BEGIN
  pkg_turismouq.sp_liquidar_mes(p_periodo => SYSDATE);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 3.9: liquidar julio de 2025 con una comision de 150%
BEGIN
  pkg_turismouq.sp_liquidar_mes(p_periodo => DATE '2025-07-01', p_porcentaje => 150);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/


-- Prueba 4: disparador trg_reserva_sin_cruce
-- Se inserta directo en las tablas, sin pasar por sp_crear_reserva, para
-- comprobar que el disparador protege aunque alguien se salte el procedimiento.
-- Al final de cada prueba se deshace con ROLLBACK.

PROMPT
PROMPT Prueba 4.1: insertar directo una reserva de la habitacion 2 del 20/03/2027 al 22/03/2027,
PROMPT             que se cruza con la reserva de la prueba 2.1
BEGIN
  INSERT INTO reserva (id_reserva, id_cliente, fecha_checkin, fecha_checkout,
                       estado, valor_total, num_huespedes)
  VALUES (99999, 5, DATE '2027-03-20', DATE '2027-03-22', 'CONFIRMADA', 0, 1);

  INSERT INTO reserva_habitacion (id_reserva, id_habitacion, id_temporada,
                                  noches, valor_noche_aplicado)
  VALUES (99999, 2,
          (SELECT id_temporada FROM temporada WHERE nombre = 'Semana Santa 2027'),
          2, 347000);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/
ROLLBACK;

PROMPT
PROMPT Prueba 4.2: insertar directo una reserva libre del 14/07/2027 al 18/07/2027 que cruza
PROMPT             dos temporadas. Lleva dos filas de la misma habitacion y se deben aceptar.
BEGIN
  INSERT INTO reserva (id_reserva, id_cliente, fecha_checkin, fecha_checkout,
                       estado, valor_total, num_huespedes)
  VALUES (99999, 5, DATE '2027-07-14', DATE '2027-07-18', 'CONFIRMADA', 0, 1);

  INSERT INTO reserva_habitacion (id_reserva, id_habitacion, id_temporada,
                                  noches, valor_noche_aplicado)
  VALUES (99999, 2,
          (SELECT id_temporada FROM temporada WHERE nombre = 'Mitad de Ano 2027'),
          2, 100000);

  INSERT INTO reserva_habitacion (id_reserva, id_habitacion, id_temporada,
                                  noches, valor_noche_aplicado)
  VALUES (99999, 2,
          (SELECT id_temporada FROM temporada WHERE nombre = 'Baja III 2027'),
          2, 100000);

  DBMS_OUTPUT.PUT_LINE('   Las dos filas se guardaron, no hay cruce.');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/
ROLLBACK;


-- Prueba 5: disparador trg_auditoria_tarifa
-- Se cambian tarifas de la habitacion 2 en 2027, se revisa la auditoria y al
-- final se deshace todo con ROLLBACK para no alterar los precios.
-- b_ultima_auditoria guarda el ultimo registro que ya existia, para mostrar
-- solo los que genere esta prueba.
VARIABLE b_ultima_auditoria NUMBER
EXEC SELECT NVL(MAX(id_auditoria), 0) INTO :b_ultima_auditoria FROM auditoria_tarifa;

PROMPT
PROMPT Prueba 5.1: una sentencia que sube 10% una sola tarifa (Semana Santa 2027)
UPDATE tarifa
SET    valor_noche = valor_noche * 1.10
WHERE  id_habitacion = 2
  AND  id_temporada  = (SELECT id_temporada FROM temporada
                        WHERE  nombre = 'Semana Santa 2027');

PROMPT
PROMPT Prueba 5.2: una sola sentencia que sube 5% las 7 tarifas de 2027 de la habitacion 2
UPDATE tarifa
SET    valor_noche = valor_noche * 1.05
WHERE  id_habitacion = 2
  AND  id_temporada IN (SELECT id_temporada FROM temporada
                        WHERE  EXTRACT(YEAR FROM fecha_inicio) = 2027);

PROMPT
PROMPT Prueba 5.3: lo que quedo en la auditoria (8 registros: 1 de la primera sentencia y 7 de la segunda)
SET LINESIZE 180;
COLUMN operacion  FORMAT A9
COLUMN usuario_bd FORMAT A10
COLUMN usuario_so FORMAT A30
COLUMN equipo     FORMAT A24
COLUMN cuando     FORMAT A19
SELECT id_auditoria, id_tarifa, operacion, valor_anterior, valor_nuevo,
       usuario_bd, usuario_so, equipo,
       TO_CHAR(fecha_cambio, 'DD/MM/YYYY HH24:MI:SS') AS cuando
FROM   auditoria_tarifa
WHERE  id_auditoria > :b_ultima_auditoria
ORDER  BY id_auditoria;

ROLLBACK;

PROMPT
PROMPT Prueba 5.4: despues del ROLLBACK la tarifa vuelve a su valor y los 8 registros desaparecen
SELECT tf.valor_noche AS tarifa_semana_santa_2027,
       (SELECT COUNT(*) FROM auditoria_tarifa
        WHERE  id_auditoria > :b_ultima_auditoria) AS registros_auditoria
FROM   tarifa tf
JOIN   temporada t ON t.id_temporada = tf.id_temporada
WHERE  tf.id_habitacion = 2
  AND  t.nombre = 'Semana Santa 2027';


-- Prueba 6: operaciones de recepcion (registrar cliente, servicios,
-- check-out y cancelacion). Todo se hace con un cliente de prueba, documento
-- 9990001; primero se borra lo que haya dejado una ejecucion anterior.
DELETE FROM pago
WHERE  id_reserva IN (SELECT r.id_reserva FROM reserva r JOIN cliente c ON c.id_cliente = r.id_cliente
                      WHERE  c.documento = '9990001');
DELETE FROM reserva_servicio
WHERE  id_reserva IN (SELECT r.id_reserva FROM reserva r JOIN cliente c ON c.id_cliente = r.id_cliente
                      WHERE  c.documento = '9990001');
DELETE FROM reserva_habitacion
WHERE  id_reserva IN (SELECT r.id_reserva FROM reserva r JOIN cliente c ON c.id_cliente = r.id_cliente
                      WHERE  c.documento = '9990001');
DELETE FROM reserva
WHERE  id_cliente IN (SELECT id_cliente FROM cliente WHERE documento = '9990001');
DELETE FROM cliente WHERE documento = '9990001';
COMMIT;

PROMPT
PROMPT Prueba 6.1: registrar un cliente nuevo
DECLARE
  v_id cliente.id_cliente%TYPE;
BEGIN
  pkg_turismouq.sp_registrar_cliente(
    p_nombre     => 'Cliente de Prueba',
    p_documento  => '9990001',
    p_email      => 'cliente.prueba@correo.com',
    p_id_cliente => v_id);
END;
/

PROMPT
PROMPT Prueba 6.2: registrar otra vez el mismo documento (DUP_VAL_ON_INDEX)
DECLARE
  v_id cliente.id_cliente%TYPE;
BEGIN
  pkg_turismouq.sp_registrar_cliente(
    p_nombre     => 'Otro Nombre',
    p_documento  => '9990001',
    p_email      => 'otro.correo@correo.com',
    p_id_cliente => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 6.3: reserva para hoy y manana del cliente de prueba, en la primera
PROMPT             habitacion que este libre esas fechas
DECLARE
  v_cli  cliente.id_cliente%TYPE;
  v_hab  habitacion.id_habitacion%TYPE;
  v_id   reserva.id_reserva%TYPE;
BEGIN
  SELECT id_cliente INTO v_cli FROM cliente WHERE documento = '9990001';

  FOR h IN (SELECT id_habitacion FROM habitacion
            WHERE  estado = 'DISPONIBLE' ORDER BY id_habitacion) LOOP
    IF pkg_turismouq.fn_habitacion_disponible(h.id_habitacion, TRUNC(SYSDATE), TRUNC(SYSDATE) + 1) THEN
      v_hab := h.id_habitacion;
      EXIT;
    END IF;
  END LOOP;

  pkg_turismouq.sp_crear_reserva(
    p_id_cliente    => v_cli,
    p_id_habitacion => v_hab,
    p_fecha_in      => TRUNC(SYSDATE),
    p_fecha_out     => TRUNC(SYSDATE) + 1,
    p_num_huespedes => 1,
    p_id_reserva    => v_id);
END;
/

PROMPT
PROMPT Prueba 6.4: cargar 2 unidades de un servicio del mismo alojamiento
DECLARE
  v_res  reserva.id_reserva%TYPE;
  v_srv  servicio.id_servicio%TYPE;
BEGIN
  SELECT MAX(r.id_reserva) INTO v_res
  FROM   reserva r JOIN cliente c ON c.id_cliente = r.id_cliente
  WHERE  c.documento = '9990001';

  SELECT MIN(s.id_servicio) INTO v_srv
  FROM   servicio s
  WHERE  s.id_alojamiento = (SELECT MIN(h.id_alojamiento)
                             FROM   reserva_habitacion rh
                             JOIN   habitacion h ON h.id_habitacion = rh.id_habitacion
                             WHERE  rh.id_reserva = v_res);

  pkg_turismouq.sp_agregar_servicio(p_id_reserva => v_res, p_id_servicio => v_srv, p_cantidad => 2);
END;
/

PROMPT
PROMPT Prueba 6.5: cargar un servicio de otro alojamiento
DECLARE
  v_res  reserva.id_reserva%TYPE;
  v_srv  servicio.id_servicio%TYPE;
BEGIN
  SELECT MAX(r.id_reserva) INTO v_res
  FROM   reserva r JOIN cliente c ON c.id_cliente = r.id_cliente
  WHERE  c.documento = '9990001';

  SELECT MIN(s.id_servicio) INTO v_srv
  FROM   servicio s
  WHERE  s.id_alojamiento <> (SELECT MIN(h.id_alojamiento)
                              FROM   reserva_habitacion rh
                              JOIN   habitacion h ON h.id_habitacion = rh.id_habitacion
                              WHERE  rh.id_reserva = v_res);

  pkg_turismouq.sp_agregar_servicio(p_id_reserva => v_res, p_id_servicio => v_srv, p_cantidad => 1);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 6.6: cancelar la reserva de hoy, que ya empezo
DECLARE
  v_res reserva.id_reserva%TYPE;
BEGIN
  SELECT MAX(r.id_reserva) INTO v_res
  FROM   reserva r JOIN cliente c ON c.id_cliente = r.id_cliente
  WHERE  c.documento = '9990001';

  pkg_turismouq.sp_cancelar_reserva(p_id_reserva => v_res);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 6.7: check-out de la reserva de 2027 de la prueba 2.1, cuyo huesped no ha llegado
DECLARE
  v_res reserva.id_reserva%TYPE;
BEGIN
  SELECT MIN(id_reserva) INTO v_res
  FROM   reserva
  WHERE  fecha_checkin = DATE '2027-03-19';

  pkg_turismouq.sp_checkout(p_id_reserva => v_res);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 6.8: check-out de la reserva de hoy: cobra el total y la deja FINALIZADA
DECLARE
  v_res reserva.id_reserva%TYPE;
BEGIN
  SELECT MAX(r.id_reserva) INTO v_res
  FROM   reserva r JOIN cliente c ON c.id_cliente = r.id_cliente
  WHERE  c.documento = '9990001';

  pkg_turismouq.sp_checkout(p_id_reserva => v_res, p_metodo_pago => 'PSE');
END;
/

PROMPT
PROMPT Prueba 6.9: cancelar la reserva de 2027 de la prueba 2.3, que todavia no empieza
DECLARE
  v_res reserva.id_reserva%TYPE;
BEGIN
  SELECT MIN(id_reserva) INTO v_res
  FROM   reserva
  WHERE  fecha_checkin = DATE '2027-03-15';

  pkg_turismouq.sp_cancelar_reserva(p_id_reserva => v_res);
END;
/

PROMPT
PROMPT Prueba 6.10: la reserva del cliente de prueba, su servicio y su pago
COLUMN cliente FORMAT A18
COLUMN estado  FORMAT A11
COLUMN metodo  FORMAT A8
SELECT r.id_reserva,
       c.nombre AS cliente,
       r.estado,
       r.valor_total,
       (SELECT NVL(SUM(rs.valor_total), 0) FROM reserva_servicio rs
        WHERE  rs.id_reserva = r.id_reserva) AS servicios,
       (SELECT NVL(SUM(p.valor), 0) FROM pago p
        WHERE  p.id_reserva = r.id_reserva) AS pagado,
       (SELECT MAX(p.metodo_pago) FROM pago p
        WHERE  p.id_reserva = r.id_reserva) AS metodo
FROM   reserva r
JOIN   cliente c ON c.id_cliente = r.id_cliente
WHERE  c.documento = '9990001';


-- Prueba 7: disparador trg_reserva_cambios
-- Se intenta modificar directo en la tabla, sin pasar por el paquete.

PROMPT
PROMPT Prueba 7.1: cambiar las fechas de la reserva de la prueba 2.1
BEGIN
  UPDATE reserva
  SET    fecha_checkout = fecha_checkout + 2
  WHERE  fecha_checkin  = DATE '2027-03-19';
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/
ROLLBACK;

PROMPT
PROMPT Prueba 7.2: reactivar la reserva de la prueba 2.3, que quedo CANCELADA
BEGIN
  UPDATE reserva
  SET    estado        = 'CONFIRMADA'
  WHERE  fecha_checkin = DATE '2027-03-15';
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/
ROLLBACK;


-- Prueba 8: operaciones de administracion (tarifas, habitaciones y
-- liquidaciones). Lo que se cambia se deja como estaba al final.

PROMPT
PROMPT Prueba 8.1: subir 1.000 la tarifa de Semana Santa 2027 de la habitacion 3 y devolverla
DECLARE
  v_tarifa  tarifa.id_tarifa%TYPE;
  v_valor   tarifa.valor_noche%TYPE;
BEGIN
  SELECT tf.id_tarifa, tf.valor_noche
  INTO   v_tarifa, v_valor
  FROM   tarifa tf
  JOIN   temporada t ON t.id_temporada = tf.id_temporada
  WHERE  tf.id_habitacion = 3
    AND  t.nombre = 'Semana Santa 2027';

  pkg_turismouq.sp_actualizar_tarifa(p_id_tarifa => v_tarifa, p_valor_noche => v_valor + 1000);
  pkg_turismouq.sp_actualizar_tarifa(p_id_tarifa => v_tarifa, p_valor_noche => v_valor);
END;
/
COLUMN operacion FORMAT A9
SELECT * FROM (
  SELECT id_auditoria, id_tarifa, operacion, valor_anterior, valor_nuevo
  FROM   auditoria_tarifa
  ORDER  BY id_auditoria DESC)
WHERE  ROWNUM <= 2;

PROMPT
PROMPT Prueba 8.2: cambiar una tarifa de una temporada que ya empezo (Baja III 2026)
DECLARE
  v_tarifa tarifa.id_tarifa%TYPE;
BEGIN
  SELECT tf.id_tarifa INTO v_tarifa
  FROM   tarifa tf
  JOIN   temporada t ON t.id_temporada = tf.id_temporada
  WHERE  tf.id_habitacion = 3
    AND  t.nombre = 'Baja III 2026';

  pkg_turismouq.sp_actualizar_tarifa(p_id_tarifa => v_tarifa, p_valor_noche => 999000);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 8.3: ajuste masivo de 150% (fuera de rango)
DECLARE
  v_afectadas NUMBER;
BEGIN
  pkg_turismouq.sp_ajustar_tarifas(p_id_alojamiento => 3, p_anio => 2027,
                                   p_porcentaje => 150, p_afectadas => v_afectadas);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 8.4: ajuste masivo sobre 2025, cuyas temporadas ya pasaron
DECLARE
  v_afectadas NUMBER;
BEGIN
  pkg_turismouq.sp_ajustar_tarifas(p_id_alojamiento => 3, p_anio => 2025,
                                   p_porcentaje => 5, p_afectadas => v_afectadas);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 8.5: estado de habitacion no permitido
BEGIN
  pkg_turismouq.sp_cambiar_estado_habitacion(p_id_habitacion => 25, p_estado => 'ROTA');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 8.6: sacar la habitacion 25 de mantenimiento y volverla a poner
BEGIN
  pkg_turismouq.sp_cambiar_estado_habitacion(p_id_habitacion => 25, p_estado => 'DISPONIBLE');
  pkg_turismouq.sp_cambiar_estado_habitacion(p_id_habitacion => 25, p_estado => 'MANTENIMIENTO');
END;
/

PROMPT
PROMPT Prueba 8.7: reabrir junio de 2025 (liquidado en la prueba 3.1) y luego intentarlo otra vez
BEGIN
  pkg_turismouq.sp_reabrir_liquidacion(p_periodo => DATE '2025-06-01');
END;
/
BEGIN
  pkg_turismouq.sp_reabrir_liquidacion(p_periodo => DATE '2025-06-01');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba 8.8: al reabrir el mes tambien se borra su detalle (ON DELETE CASCADE)
SELECT (SELECT COUNT(*) FROM liquidacion_mensual WHERE periodo = DATE '2025-06-01') AS totales,
       (SELECT COUNT(*) FROM liquidacion_detalle WHERE periodo = DATE '2025-06-01') AS reservas_detalle
FROM   dual;
