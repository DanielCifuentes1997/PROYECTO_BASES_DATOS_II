SET ECHO OFF
SET DEFINE OFF
SET LINESIZE 110
SET PAGESIZE 50
SET TAB OFF
SET FEEDBACK ON
COLUMN municipio        FORMAT A16
COLUMN numero_clientes  FORMAT 999999
COLUMN numero_reservas  FORMAT 999999
COLUMN noches_vendidas  FORMAT 999999
SET ECHO ON
SELECT m.nombre AS municipio,
       COUNT(DISTINCT r.id_cliente) AS numero_clientes,
       COUNT(DISTINCT r.id_reserva) AS numero_reservas,
       SUM(rh.noches) AS noches_vendidas
FROM municipio m
JOIN alojamiento a ON a.id_municipio = m.id_municipio
JOIN habitacion h ON h.id_alojamiento = a.id_alojamiento
JOIN reserva_habitacion rh ON rh.id_habitacion = h.id_habitacion
JOIN reserva r ON r.id_reserva = rh.id_reserva
WHERE r.estado <> 'CANCELADA'
GROUP BY m.nombre
ORDER BY numero_clientes DESC;
