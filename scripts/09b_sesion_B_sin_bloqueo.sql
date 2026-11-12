-- TurismoUQ - Experimento de concurrencia, paso 2 (SESION B, sin bloqueo)
-- Hace exactamente lo mismo que la sesion A, para otro cliente, mientras A
-- todavia no confirma. B no ve la reserva de A (Oracle solo le muestra lo
-- confirmado), asi que la habitacion le aparece libre y tambien la reserva.

SET SERVEROUTPUT ON;
SET FEEDBACK OFF;

DECLARE
  v_id_reserva  reserva.id_reserva%TYPE;
  v_temporada   temporada.id_temporada%TYPE;
  v_valor_noche tarifa.valor_noche%TYPE;
BEGIN
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

    DBMS_OUTPUT.PUT_LINE('Sesion B: reserva ' || v_id_reserva || ' registrada, SIN COMMIT.');
    DBMS_OUTPUT.PUT_LINE('Ahora haga COMMIT en la sesion A y despues en la sesion B.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Sesion B: la habitacion 6 ya esta ocupada.');
  END IF;
END;
/
SET FEEDBACK ON;
