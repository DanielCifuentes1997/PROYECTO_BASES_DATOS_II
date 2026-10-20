-- TurismoUQ - Script 03: consultas de analisis
-- El ingreso se calcula como noches x tarifa sobre RESERVA_HABITACION y no con
-- RESERVA.valor_total, porque una reserva puede tener varias habitaciones.
-- Las reservas canceladas no se cuentan.
-- Ejecutar como TURISMOUQ

SET DEFINE OFF;
SET LINESIZE 160;
SET PAGESIZE 100;
SET TAB OFF;

-- Consulta 1: ocupacion (%) por municipio y mes en 2025, con PIVOT
-- ocupacion = noches vendidas / (habitaciones del municipio x dias del mes) x 100
COLUMN municipio FORMAT A14

WITH inventario AS (
  SELECT m.nombre AS municipio, COUNT(*) AS habitaciones
  FROM   habitacion  h
  JOIN   alojamiento a ON a.id_alojamiento = h.id_alojamiento
  JOIN   municipio   m ON m.id_municipio   = a.id_municipio
  GROUP  BY m.nombre
),
vendido AS (
  SELECT m.nombre                                            AS municipio,
         TO_CHAR(r.fecha_checkin, 'MM')                      AS mes,
         SUM(rh.noches)                                      AS noches,
         MAX(TO_NUMBER(TO_CHAR(LAST_DAY(r.fecha_checkin), 'DD'))) AS dias_mes
  FROM   reserva            r
  JOIN   reserva_habitacion rh ON rh.id_reserva     = r.id_reserva
  JOIN   habitacion         h  ON h.id_habitacion   = rh.id_habitacion
  JOIN   alojamiento        a  ON a.id_alojamiento  = h.id_alojamiento
  JOIN   municipio          m  ON m.id_municipio    = a.id_municipio
  WHERE  r.estado <> 'CANCELADA'
    AND  EXTRACT(YEAR FROM r.fecha_checkin) = 2025
  GROUP  BY m.nombre, TO_CHAR(r.fecha_checkin, 'MM')
)
SELECT *
FROM (
  SELECT v.municipio,
         v.mes,
         ROUND(v.noches * 100 / (i.habitaciones * v.dias_mes), 1) AS pct
  FROM   vendido v
  JOIN   inventario i ON i.municipio = v.municipio
)
PIVOT (
  MAX(pct) FOR mes IN ('01' AS ENE, '02' AS FEB, '03' AS MAR, '04' AS ABR,
                       '05' AS MAY, '06' AS JUN, '07' AS JUL, '08' AS AGO,
                       '09' AS SEP, '10' AS OCT, '11' AS NOV, '12' AS DIC)
)
ORDER BY municipio;

-- Consulta 2: ingresos por municipio, tipo de alojamiento y temporada con ROLLUP.
-- GROUPING indica si la fila es un subtotal (1) o un dato (0).
COLUMN municipio FORMAT A14
COLUMN tipo_alojamiento FORMAT A22
COLUMN temporada FORMAT A12
COLUMN nivel FORMAT A26
COLUMN ingresos_millones FORMAT 999G999D9 HEADING "INGRESOS_MILL"

SELECT CASE WHEN GROUPING(m.nombre)  = 1 THEN '(todos)' ELSE m.nombre  END AS municipio,
       CASE WHEN GROUPING(ta.nombre) = 1 THEN '(todos)' ELSE ta.nombre END AS tipo_alojamiento,
       CASE WHEN GROUPING(t.tipo)    = 1 THEN '(todas)' ELSE t.tipo    END AS temporada,
       COUNT(DISTINCT r.id_reserva)                                        AS reservas,
       ROUND(SUM(rh.noches * rh.valor_noche_aplicado) / 1000000, 1)        AS ingresos_millones,
       CASE GROUPING_ID(m.nombre, ta.nombre, t.tipo)
         WHEN 0 THEN 'dato'
         WHEN 1 THEN 'subtotal tipo'
         WHEN 3 THEN 'subtotal municipio'
         WHEN 7 THEN 'TOTAL GENERAL'
       END                                                                 AS nivel
FROM   reserva            r
JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
JOIN   temporada          t  ON t.id_temporada   = rh.id_temporada
JOIN   habitacion         h  ON h.id_habitacion  = rh.id_habitacion
JOIN   alojamiento        a  ON a.id_alojamiento = h.id_alojamiento
JOIN   tipo_alojamiento   ta ON ta.id_tipo       = a.id_tipo
JOIN   municipio          m  ON m.id_municipio   = a.id_municipio
WHERE  r.estado <> 'CANCELADA'
  AND  EXTRACT(YEAR FROM r.fecha_checkin) = 2025
  AND  m.nombre IN ('Armenia', 'Salento', 'Filandia')
GROUP  BY ROLLUP (m.nombre, ta.nombre, t.tipo)
ORDER  BY GROUPING(m.nombre), m.nombre,
          GROUPING(ta.nombre), ta.nombre,
          GROUPING(t.tipo), t.tipo;

-- Consulta 3: los 3 alojamientos con mas ingresos en cada municipio (RANK con PARTITION BY).
-- Va dentro de una subconsulta porque RANK se calcula despues del GROUP BY.
COLUMN municipio FORMAT A14
COLUMN alojamiento FORMAT A26
COLUMN tipo FORMAT A22
COLUMN ingresos_millones FORMAT 999G999D9 HEADING "INGRESOS_MILL"
COLUMN puesto FORMAT 999

SELECT municipio, puesto, alojamiento, tipo, reservas, ingresos_millones
FROM (
  SELECT m.nombre                                                       AS municipio,
         a.nombre                                                       AS alojamiento,
         ta.nombre                                                      AS tipo,
         COUNT(DISTINCT r.id_reserva)                                   AS reservas,
         ROUND(SUM(rh.noches * rh.valor_noche_aplicado) / 1000000, 1)   AS ingresos_millones,
         RANK() OVER (PARTITION BY m.nombre
                      ORDER BY SUM(rh.noches * rh.valor_noche_aplicado) DESC) AS puesto
  FROM   reserva            r
  JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
  JOIN   habitacion         h  ON h.id_habitacion  = rh.id_habitacion
  JOIN   alojamiento        a  ON a.id_alojamiento = h.id_alojamiento
  JOIN   tipo_alojamiento   ta ON ta.id_tipo       = a.id_tipo
  JOIN   municipio          m  ON m.id_municipio   = a.id_municipio
  WHERE  r.estado <> 'CANCELADA'
  GROUP  BY m.nombre, a.nombre, ta.nombre
)
WHERE puesto <= 3
ORDER BY municipio, puesto;

-- Consulta 4: variacion de ingresos mes contra mes con LAG
COLUMN mes FORMAT A9
COLUMN ingresos_millones FORMAT 999G999D9 HEADING "INGRESOS_MILL"
COLUMN mes_anterior      FORMAT 999G999D9 HEADING "MES_ANTERIOR"
COLUMN variacion         FORMAT 999G999D9 HEADING "VARIACION"
COLUMN variacion_pct     FORMAT 9990D9    HEADING "VAR_%"

WITH ingresos_mes AS (
  SELECT TRUNC(r.fecha_checkin, 'MM')              AS mes,
         SUM(rh.noches * rh.valor_noche_aplicado)  AS ingresos
  FROM   reserva            r
  JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
  WHERE  r.estado <> 'CANCELADA'
  GROUP  BY TRUNC(r.fecha_checkin, 'MM')
)
SELECT TO_CHAR(mes, 'YYYY-MM')                                        AS mes,
       ROUND(ingresos / 1000000, 1)                                   AS ingresos_millones,
       ROUND(LAG(ingresos) OVER (ORDER BY mes) / 1000000, 1)          AS mes_anterior,
       ROUND((ingresos - LAG(ingresos) OVER (ORDER BY mes))
             / 1000000, 1)                                            AS variacion,
       ROUND((ingresos - LAG(ingresos) OVER (ORDER BY mes)) * 100
             / LAG(ingresos) OVER (ORDER BY mes), 1)                  AS variacion_pct
FROM   ingresos_mes
ORDER  BY mes;

-- Consulta 5: consulta parametrizada con variables de enlace (rango de fechas)
VARIABLE b_fecha_ini VARCHAR2(10)
VARIABLE b_fecha_fin VARCHAR2(10)

EXEC :b_fecha_ini := '2025-06-15';
EXEC :b_fecha_fin := '2025-07-15';

COLUMN municipio FORMAT A14
COLUMN tipo_alojamiento FORMAT A22
COLUMN ingresos_millones FORMAT 999G999D9 HEADING "INGRESOS_MILL"

SELECT m.nombre                                                     AS municipio,
       ta.nombre                                                    AS tipo_alojamiento,
       COUNT(DISTINCT r.id_reserva)                                 AS reservas,
       SUM(rh.noches)                                               AS noches,
       ROUND(SUM(rh.noches * rh.valor_noche_aplicado) / 1000000, 1) AS ingresos_millones
FROM   reserva            r
JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
JOIN   habitacion         h  ON h.id_habitacion  = rh.id_habitacion
JOIN   alojamiento        a  ON a.id_alojamiento = h.id_alojamiento
JOIN   tipo_alojamiento   ta ON ta.id_tipo       = a.id_tipo
JOIN   municipio          m  ON m.id_municipio   = a.id_municipio
WHERE  r.estado <> 'CANCELADA'
  AND  r.fecha_checkin BETWEEN TO_DATE(:b_fecha_ini, 'YYYY-MM-DD')
                           AND TO_DATE(:b_fecha_fin, 'YYYY-MM-DD')
GROUP  BY m.nombre, ta.nombre
ORDER  BY ingresos_millones DESC
FETCH FIRST 15 ROWS ONLY;

-- Consulta 6: vista materializada de ocupacion mensual.
-- Refresco completo, bajo demanda y automatico cada 24 horas.
BEGIN
  EXECUTE IMMEDIATE 'DROP MATERIALIZED VIEW mv_ocupacion_mensual';
EXCEPTION
  WHEN OTHERS THEN NULL;   -- no existia todavia
END;
/

CREATE MATERIALIZED VIEW mv_ocupacion_mensual
BUILD IMMEDIATE
REFRESH COMPLETE
START WITH SYSDATE NEXT SYSDATE + 1
AS
SELECT m.id_municipio,
       m.nombre                                   AS municipio,
       TRUNC(r.fecha_checkin, 'MM')               AS mes,
       COUNT(DISTINCT r.id_reserva)               AS reservas,
       SUM(rh.noches)                             AS noches_vendidas,
       SUM(rh.noches * rh.valor_noche_aplicado)   AS ingresos
FROM   reserva            r
JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
JOIN   habitacion         h  ON h.id_habitacion  = rh.id_habitacion
JOIN   alojamiento        a  ON a.id_alojamiento = h.id_alojamiento
JOIN   municipio          m  ON m.id_municipio   = a.id_municipio
WHERE  r.estado <> 'CANCELADA'
GROUP  BY m.id_municipio, m.nombre, TRUNC(r.fecha_checkin, 'MM');

-- Consulta sobre la vista materializada
COLUMN municipio FORMAT A14
COLUMN mes FORMAT A9
COLUMN ingresos_millones FORMAT 999G999D9 HEADING "INGRESOS_MILL"

SELECT municipio,
       TO_CHAR(mes, 'YYYY-MM')        AS mes,
       reservas,
       noches_vendidas,
       ROUND(ingresos / 1000000, 1)   AS ingresos_millones
FROM   mv_ocupacion_mensual
WHERE  mes BETWEEN DATE '2025-06-01' AND DATE '2025-08-01'
ORDER  BY municipio, mes;

-- Consulta 7: UNPIVOT, pasa noches y clientes por temporada de columnas a filas
COLUMN municipio FORMAT A14
COLUMN metrica   FORMAT A10
COLUMN temporada FORMAT A6
COLUMN valor     FORMAT 999G999

WITH resumen_ancho AS (
  SELECT m.nombre AS municipio,
         SUM(CASE WHEN t.tipo = 'ALTA' THEN rh.noches ELSE 0 END) AS noches_alta,
         SUM(CASE WHEN t.tipo = 'BAJA' THEN rh.noches ELSE 0 END) AS noches_baja,
         COUNT(DISTINCT CASE WHEN t.tipo = 'ALTA' THEN r.id_cliente END) AS clientes_alta,
         COUNT(DISTINCT CASE WHEN t.tipo = 'BAJA' THEN r.id_cliente END) AS clientes_baja
  FROM   reserva            r
  JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
  JOIN   temporada          t  ON t.id_temporada   = rh.id_temporada
  JOIN   habitacion         h  ON h.id_habitacion  = rh.id_habitacion
  JOIN   alojamiento        a  ON a.id_alojamiento = h.id_alojamiento
  JOIN   municipio          m  ON m.id_municipio   = a.id_municipio
  WHERE  r.estado <> 'CANCELADA'
  GROUP  BY m.nombre
)
SELECT municipio, metrica, temporada, valor
FROM   resumen_ancho
UNPIVOT (
  valor FOR (metrica, temporada) IN (
    noches_alta   AS ('NOCHES',   'ALTA'),
    noches_baja   AS ('NOCHES',   'BAJA'),
    clientes_alta AS ('CLIENTES', 'ALTA'),
    clientes_baja AS ('CLIENTES', 'BAJA')
  )
)
ORDER BY municipio, metrica, temporada;

-- Consulta 8 (libre): alojamientos bien calificados pero con pocas ventas,
-- candidatos a promocion. Minimo 25 resenas para que el promedio sea confiable.
COLUMN alojamiento FORMAT A26
COLUMN municipio   FORMAT A14
COLUMN tipo        FORMAT A22
COLUMN calificacion FORMAT 90D99 HEADING "CALIF_PROM"
COLUMN resenas      FORMAT 9G999 HEADING "RESENAS"
COLUMN noches       FORMAT 99G999
COLUMN puesto_calidad FORMAT 999 HEADING "PUESTO|CALIDAD"
COLUMN puesto_ventas  FORMAT 999 HEADING "PUESTO|VENTAS"
COLUMN brecha         FORMAT S999 HEADING "BRECHA"

SELECT alojamiento, municipio, tipo, calificacion, resenas, noches,
       puesto_calidad, puesto_ventas,
       puesto_ventas - puesto_calidad AS brecha
FROM (
  SELECT a.nombre                                            AS alojamiento,
         m.nombre                                            AS municipio,
         ta.nombre                                           AS tipo,
         ROUND(AVG(rs.calificacion), 2)                      AS calificacion,
         COUNT(DISTINCT rs.id_resena)                        AS resenas,
         SUM(rh.noches)                                      AS noches,
         RANK() OVER (ORDER BY AVG(rs.calificacion) DESC)    AS puesto_calidad,
         RANK() OVER (ORDER BY SUM(rh.noches) DESC)          AS puesto_ventas
  FROM   resena             rs
  JOIN   reserva            r  ON r.id_reserva     = rs.id_reserva
  JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
  JOIN   habitacion         h  ON h.id_habitacion  = rh.id_habitacion
  JOIN   alojamiento        a  ON a.id_alojamiento = h.id_alojamiento
  JOIN   tipo_alojamiento   ta ON ta.id_tipo       = a.id_tipo
  JOIN   municipio          m  ON m.id_municipio   = a.id_municipio
  GROUP  BY a.nombre, m.nombre, ta.nombre
  HAVING COUNT(DISTINCT rs.id_resena) >= 25
)
ORDER BY brecha DESC
FETCH FIRST 10 ROWS ONLY;

CLEAR COLUMNS;
