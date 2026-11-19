-- TurismoUQ - Script 14: consultas de la sustentacion
-- 1. La habitacion con mas reservas en temporada alta.
-- 2. El cliente con mas reservas en cada municipio.
-- Igual que en el script 03, las reservas canceladas no se cuentan.
-- Ejecutar como TURISMOUQ

SET DEFINE OFF;
SET LINESIZE 160;
SET PAGESIZE 100;
SET TAB OFF;
SET FEEDBACK ON;


-- =====================================================================
-- Consulta 1: habitacion con mas reservas en temporada alta
-- Una reserva cuenta para la temporada alta si al menos una de sus noches
-- cae en una temporada de tipo ALTA. Como una estadia puede partirse en dos
-- temporadas (dos filas en RESERVA_HABITACION), se cuenta COUNT(DISTINCT
-- id_reserva) para no contar dos veces la misma reserva.
-- Si dos habitaciones empatan en reservas gana la que vendio mas noches en
-- temporada alta; si tambien empatan en eso, RANK deja a las dos en el mismo
-- puesto. Se muestran los 5 primeros puestos para ver la diferencia.
-- =====================================================================
COLUMN puesto        FORMAT 999
COLUMN alojamiento   FORMAT A24
COLUMN municipio     FORMAT A12
COLUMN habitacion    FORMAT A10
COLUMN tipo          FORMAT A10
COLUMN reservas      FORMAT 99G999
COLUMN noches_alta   FORMAT 99G999
COLUMN ingresos_alta FORMAT 999G999G999

PROMPT
PROMPT ===================================================================
PROMPT CONSULTA 1: habitacion con mas reservas en temporada alta
PROMPT ===================================================================

WITH reservas_alta AS (
  SELECT rh.id_habitacion,
         COUNT(DISTINCT rh.id_reserva)          AS reservas,
         SUM(rh.noches)                         AS noches_alta,
         SUM(rh.noches * rh.valor_noche_aplicado) AS ingresos_alta
  FROM   reserva_habitacion rh
  JOIN   reserva   r ON r.id_reserva   = rh.id_reserva
  JOIN   temporada t ON t.id_temporada = rh.id_temporada
  WHERE  t.tipo   = 'ALTA'
    AND  r.estado <> 'CANCELADA'
  GROUP  BY rh.id_habitacion
),
ranking AS (
  SELECT RANK() OVER (ORDER BY ra.reservas DESC, ra.noches_alta DESC) AS puesto,
         a.nombre        AS alojamiento,
         m.nombre        AS municipio,
         'Hab. ' || h.numero AS habitacion,
         h.tipo_habitacion AS tipo,
         ra.reservas,
         ra.noches_alta,
         ra.ingresos_alta
  FROM   reservas_alta ra
  JOIN   habitacion  h ON h.id_habitacion  = ra.id_habitacion
  JOIN   alojamiento a ON a.id_alojamiento = h.id_alojamiento
  JOIN   municipio   m ON m.id_municipio   = a.id_municipio
)
SELECT puesto, alojamiento, municipio, habitacion, tipo, reservas, noches_alta, ingresos_alta
FROM   ranking
WHERE  puesto <= 5
ORDER  BY puesto, alojamiento, habitacion;


-- =====================================================================
-- Consulta 2: el cliente con mas reservas en cada municipio
-- Primero se cuenta cuantas reservas hizo cada cliente en cada municipio
-- (la reserva pertenece al municipio del alojamiento de su habitacion).
-- PARTITION BY municipio hace que el ranking empiece de nuevo en cada
-- municipio. Si dos clientes empatan en reservas gana el que mas gasto, y si
-- tambien empatan en eso, los dos quedan en el puesto 1.
-- =====================================================================
COLUMN cliente     FORMAT A24
COLUMN documento   FORMAT A12
COLUMN noches      FORMAT 9G999
COLUMN gastado     FORMAT 999G999G999

PROMPT
PROMPT ===================================================================
PROMPT CONSULTA 2: cliente con mas reservas en cada municipio
PROMPT ===================================================================

WITH reservas_cliente AS (
  SELECT m.nombre                             AS municipio,
         c.id_cliente,
         c.nombre                             AS cliente,
         c.documento,
         COUNT(DISTINCT r.id_reserva)         AS reservas,
         SUM(rh.noches)                       AS noches,
         SUM(rh.noches * rh.valor_noche_aplicado) AS gastado
  FROM   reserva            r
  JOIN   cliente            c  ON c.id_cliente     = r.id_cliente
  JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
  JOIN   habitacion         h  ON h.id_habitacion  = rh.id_habitacion
  JOIN   alojamiento        a  ON a.id_alojamiento = h.id_alojamiento
  JOIN   municipio          m  ON m.id_municipio   = a.id_municipio
  WHERE  r.estado <> 'CANCELADA'
  GROUP  BY m.nombre, c.id_cliente, c.nombre, c.documento
),
ranking AS (
  SELECT rc.*,
         RANK() OVER (PARTITION BY rc.municipio
                      ORDER BY rc.reservas DESC, rc.gastado DESC) AS puesto
  FROM   reservas_cliente rc
)
SELECT municipio, cliente, documento, reservas, noches, gastado
FROM   ranking
WHERE  puesto = 1
ORDER  BY municipio;
