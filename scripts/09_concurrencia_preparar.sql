-- TurismoUQ - Script 09: experimento de concurrencia (Entrega 3)
-- Prepara el experimento: deja libre la habitacion 6 entre el 10 y el 12 de
-- junio de 2027 y muestra que no tiene reservas en esas fechas.
-- Ejecutar como TURISMOUQ antes de abrir las dos sesiones.
--
-- Orden del experimento (dos ventanas de SQL*Plus, sesion A y sesion B):
--   SIN BLOQUEO (antes)
--     1. Sesion A: @09a_sesion_A_sin_bloqueo.sql   (reserva y NO confirma)
--     2. Sesion B: @09b_sesion_B_sin_bloqueo.sql   (tambien la ve libre y reserva)
--     3. Sesion A: COMMIT;
--     4. Sesion B: COMMIT;
--     5. Cualquiera: @09f_resultado.sql            (quedaron dos reservas cruzadas)
--     6. Cualquiera: @09_concurrencia_preparar.sql (limpia para la segunda parte)
--   CON BLOQUEO (despues)
--     7. Sesion A: @09c_sesion_A_con_bloqueo.sql   (bloquea la habitacion y reserva)
--     8. Sesion B: @09d_sesion_B_con_bloqueo.sql   (se queda esperando)
--     9. Sesion A: @09e_monitor_bloqueos.sql       (muestra que B espera a A)
--    10. Sesion A: COMMIT;                         (B continua y es rechazada)
--    11. Sesion B: ROLLBACK;
--    12. Cualquiera: @09f_resultado.sql            (solo quedo la reserva de A)

SET SERVEROUTPUT ON;
SET FEEDBACK OFF;

BEGIN
  FOR r IN (SELECT DISTINCT rh.id_reserva
            FROM   reserva_habitacion rh
            JOIN   reserva re ON re.id_reserva = rh.id_reserva
            WHERE  rh.id_habitacion = 6
              AND  re.fecha_checkin BETWEEN DATE '2027-06-01' AND DATE '2027-06-30') LOOP
    DELETE FROM pago               WHERE id_reserva = r.id_reserva;
    DELETE FROM reserva_servicio   WHERE id_reserva = r.id_reserva;
    DELETE FROM reserva_habitacion WHERE id_reserva = r.id_reserva;
    DELETE FROM reserva            WHERE id_reserva = r.id_reserva;
  END LOOP;
  COMMIT;
END;
/

PROMPT Habitacion 6 del 10 al 12 de junio de 2027:
BEGIN
  IF pkg_turismouq.fn_habitacion_disponible(6, DATE '2027-06-10', DATE '2027-06-12') THEN
    DBMS_OUTPUT.PUT_LINE('Libre. Ya se puede hacer el experimento.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Ocupada. Revise que ninguna sesion tenga una transaccion abierta.');
  END IF;
END;
/
SET FEEDBACK ON;
