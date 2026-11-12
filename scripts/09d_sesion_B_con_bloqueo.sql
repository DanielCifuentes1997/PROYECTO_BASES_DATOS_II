-- TurismoUQ - Experimento de concurrencia, paso 8 (SESION B, con bloqueo)
-- Intenta bloquear la misma habitacion. Como la sesion A la tiene bloqueada,
-- esta sesion se queda esperando en el SELECT ... FOR UPDATE. Cuando A hace
-- COMMIT, B continua, ahora si ve la reserva de A y la rechaza con -20001.
-- Despues de ver el error, ejecute ROLLBACK en esta sesion.

SET SERVEROUTPUT ON;
SET FEEDBACK OFF;

DECLARE
  v_id_reserva  reserva.id_reserva%TYPE;
  v_temporada   temporada.id_temporada%TYPE;
  v_valor_noche tarifa.valor_noche%TYPE;
  v_estado      habitacion.estado%TYPE;
BEGIN
  -- Antes de revisar la disponibilidad se bloquea la fila de la habitacion.
  -- Si otra sesion ya la tiene bloqueada, esta instruccion espera hasta que
  -- esa sesion haga COMMIT o ROLLBACK.
  SELECT estado
  INTO   v_estado
  FROM   habitacion
  WHERE  id_habitacion = 6
  FOR UPDATE;

  IF pkg_turismouq.fn_habitacion_disponible(6, DATE '2027-06-10', DATE '2027-06-12') THEN
    DBMS_OUTPUT.PUT_LINE('Sesion B: la habitacion 6 aparece libre.');

    v_id_reserva := seq_reserva.NEXTVAL;
    INSERT INTO reserva (id_reserva, id_cliente, fecha_checkin, fecha_checkout,
                         estado, valor_total, num_huespedes)
    VALUES (v_id_reserva, 21, DATE '2027-06-10', DATE '2027-06-12', 'CONFIRMADA',
            pkg_turismouq.fn_valor_estadia(6, DATE '2027-06-10', DATE '2027-06-12'), 1);

    SELECT t.id_temporada, tf.valor_noche
    INTO   v_temporada, v_valor_noche
    FROM   temporada t
    JOIN   tarifa tf ON tf.id_temporada = t.id_temporada AND tf.id_habitacion = 6
    WHERE  DATE '2027-06-10' BETWEEN t.fecha_inicio AND t.fecha_fin;

    INSERT INTO reserva_habitacion (id_reserva, id_habitacion, id_temporada,
                                    noches, valor_noche_aplicado)
    VALUES (v_id_reserva, 6, v_temporada, 2, v_valor_noche);

    DBMS_OUTPUT.PUT_LINE('Sesion B: reserva ' || v_id_reserva || ' registrada, SIN COMMIT. La habitacion queda bloqueada.');
  ELSE
    RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_no_disponible,
      'Sesion B: la habitacion 6 ya esta reservada entre el 10/06/2027 y el 12/06/2027.');
  END IF;
END;
/
SET FEEDBACK ON;
