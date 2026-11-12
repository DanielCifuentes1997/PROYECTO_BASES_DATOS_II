-- TurismoUQ - Experimento de concurrencia: resultado
-- Muestra las reservas que quedaron para la habitacion 6 del 10 al 12 de
-- junio de 2027 y cuantas parejas de reservas se cruzan.

SET LINESIZE 120;
COLUMN cliente FORMAT A22

PROMPT Reservas confirmadas de la habitacion 6 en esas fechas:
SELECT r.id_reserva, c.nombre AS cliente, r.fecha_checkin, r.fecha_checkout, r.estado
FROM   reserva r
JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
JOIN   cliente c             ON c.id_cliente  = r.id_cliente
WHERE  rh.id_habitacion = 6
  AND  r.fecha_checkin  < DATE '2027-06-12'
  AND  r.fecha_checkout > DATE '2027-06-10'
  AND  r.estado <> 'CANCELADA'
ORDER  BY r.id_reserva;

PROMPT Parejas de reservas cruzadas en la habitacion 6 (con bloqueo debe dar 0):
SELECT COUNT(*) AS reservas_cruzadas
FROM   reserva_habitacion a
JOIN   reserva ra ON ra.id_reserva = a.id_reserva
JOIN   reserva_habitacion b ON b.id_habitacion = a.id_habitacion AND b.id_reserva > a.id_reserva
JOIN   reserva rb ON rb.id_reserva = b.id_reserva
WHERE  a.id_habitacion = 6
  AND  ra.estado <> 'CANCELADA' AND rb.estado <> 'CANCELADA'
  AND  ra.fecha_checkin < rb.fecha_checkout
  AND  rb.fecha_checkin < ra.fecha_checkout;
