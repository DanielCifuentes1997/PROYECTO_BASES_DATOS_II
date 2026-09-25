-- ============================================================================
-- Proyecto Integrador TurismoUQ  |  Script 03 - Las 8 consultas de analisis
-- Universidad del Quindio - Bases de Datos II - codigo 12338 - periodo 2026-2
-- Autor: Daniel Esteban Cifuentes Blandon
--
-- COMO SE CALCULA EL INGRESO EN TODO ESTE SCRIPT
-- El ingreso de alojamiento sale de RESERVA_HABITACION:
--        SUM(noches * valor_noche_aplicado)
-- y NO de RESERVA.valor_total. Razon: una reserva puede tomar varias
-- habitaciones, asi que sumar valor_total despues de un JOIN lo contaria
-- varias veces. Ademas RESERVA_HABITACION ya trae las noches separadas por
-- temporada, que es justo lo que se necesita para abrir por ALTA / BAJA.
--
-- Las reservas CANCELADA se excluyen siempre: no generaron ingreso.
-- ============================================================================
SET DEFINE OFF;
SET LINESIZE 160;
SET PAGESIZE 100;
SET TAB OFF;


-- ############################################################################
-- CONSULTA 1  -  OCUPACION POR MUNICIPIO Y MES, CON PIVOT
-- ----------------------------------------------------------------------------
-- Pregunta: como se mueve el porcentaje de ocupacion de cada municipio a lo
-- largo de 2025. Se espera ver los picos de Semana Santa, mitad de ano y
-- diciembre, que es la estacionalidad del turismo en el Quindio.
--
-- Ocupacion = noches vendidas / noches disponibles * 100
--   noches disponibles = habitaciones del municipio x dias del mes
--
-- PIVOT convierte las 12 filas de meses de cada municipio en 12 COLUMNAS.
-- Sin PIVOT habria 144 filas; con PIVOT hay 12, una por municipio.
-- ############################################################################
COLUMN municipio FORMAT A14

WITH inventario AS (
  -- cuantas habitaciones tiene cada municipio (el denominador)
  SELECT m.nombre AS municipio, COUNT(*) AS habitaciones
  FROM   habitacion  h
  JOIN   alojamiento a ON a.id_alojamiento = h.id_alojamiento
  JOIN   municipio   m ON m.id_municipio   = a.id_municipio
  GROUP  BY m.nombre
),
vendido AS (
  -- noches vendidas por municipio y mes, y cuantos dias tiene ese mes
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


-- ############################################################################
-- CONSULTA 2  -  INGRESOS CON ROLLUP Y GROUPING
-- ----------------------------------------------------------------------------
-- Pregunta: ingresos por municipio, tipo de alojamiento y temporada, con los
-- subtotales de cada nivel y el total general, en una sola pasada.
--
-- ROLLUP(a, b, c) produce 4 niveles: (a,b,c), (a,b), (a) y el total.
-- GROUPING(col) devuelve 1 cuando esa columna fue colapsada por el ROLLUP,
-- o sea cuando la fila es un subtotal y no un dato. Sirve para no confundir
-- un subtotal con una fila real cuyo valor fuera NULL.
-- GROUPING_ID junta esos bits en un numero y asi se nombra el nivel directo.
--
-- Se limita a 2025 para que la salida quepa en pantalla en la sustentacion.
-- ############################################################################
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


-- ############################################################################
-- CONSULTA 3  -  LOS 3 ALOJAMIENTOS DE MAYOR INGRESO EN CADA MUNICIPIO
--                (RANK con PARTITION BY)
-- ----------------------------------------------------------------------------
-- PARTITION BY m.nombre  -> el ranking se reinicia en cada municipio
-- ORDER BY ingresos DESC -> el puesto 1 es el que mas factura
--
-- La funcion de ventana se evalua DESPUES del GROUP BY y DESPUES del HAVING,
-- por eso no se puede filtrar con WHERE puesto <= 3 en la misma consulta:
-- hay que envolverla en una subconsulta. Ese es el motivo del SELECT de afuera.
--
-- Se usa RANK y no ROW_NUMBER porque si dos alojamientos empatan en ingresos
-- ambos deben quedar en el mismo puesto, no uno arriba del otro por azar.
-- ############################################################################
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


-- ############################################################################
-- CONSULTA 4  -  VARIACION DE INGRESOS MES CONTRA MES (LAG)
-- ----------------------------------------------------------------------------
-- LAG(x) OVER (ORDER BY mes) trae el valor de la fila anterior sin necesidad
-- de un self-join de la tabla consigo misma. El primer mes no tiene anterior,
-- por eso da NULL y la variacion tambien: es correcto, no es un error.
-- ############################################################################
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


-- ############################################################################
-- CONSULTA 5  -  CONSULTA PARAMETRIZADA CON VARIABLES DE ENLACE
-- ----------------------------------------------------------------------------
-- Las variables de enlace (bind variables) se escriben con dos puntos: :nombre
--
-- Por que usarlas en vez de concatenar la fecha dentro del texto del SQL:
--   1. Oracle guarda UN solo plan de ejecucion para la consulta y lo reutiliza
--      con cualquier rango de fechas. Concatenando, cada rango seria un SQL
--      distinto, con hard parse nuevo y basura en la shared pool.
--   2. No hay inyeccion de SQL: el valor viaja como dato, nunca como codigo.
-- ############################################################################
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


-- ############################################################################
-- CONSULTA 6  -  VISTA MATERIALIZADA DE OCUPACION MENSUAL
-- ----------------------------------------------------------------------------
-- Una vista normal vuelve a ejecutar el JOIN de 25.000 reservas cada vez que
-- alguien la consulta. Una vista MATERIALIZADA guarda el resultado en disco,
-- como una tabla, y la consulta se vuelve un scan de 400 filas.
--
-- POLITICA DE REFRESCO ELEGIDA: REFRESH COMPLETE ON DEMAND, automatico cada
-- noche (START WITH ... NEXT SYSDATE + 1).
--
-- Por que COMPLETE y no FAST:
--   FAST necesita materialized view logs en las 5 tablas del JOIN y no admite
--   COUNT(DISTINCT). El costo de mantener esos logs en cada INSERT de reserva
--   es permanente; recalcular 400 filas una vez en la madrugada cuesta segundos.
--
-- Por que ON DEMAND y no ON COMMIT:
--   ON COMMIT recalcularia el agregado dentro de la transaccion de CADA
--   reserva nueva. Eso encarece la operacion que mas se repite en el sistema
--   para beneficiar a un reporte gerencial que se mira una vez al dia.
--
-- Por que diario y no mas seguido:
--   es un indicador mensual de ocupacion. Un dato con hasta 24 horas de
--   desfase no cambia ninguna decision de negocio.
-- ############################################################################
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

-- Consulta contra la vista materializada: ya no toca las 5 tablas
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


-- ############################################################################
-- CONSULTA 7  -  UNPIVOT
-- ----------------------------------------------------------------------------
-- PIVOT pasa filas a columnas; UNPIVOT hace lo contrario.
--
-- Aqui se arma primero un resumen "ancho": una fila por municipio con cuatro
-- columnas (noches y clientes, en temporada alta y en baja). Ese formato es
-- comodo para leerlo en pantalla pero incomodo para graficarlo o filtrarlo.
-- UNPIVOT lo devuelve a formato "largo": una fila por municipio, metrica y
-- temporada, que es la forma normalizada.
-- ############################################################################
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


-- ############################################################################
-- CONSULTA 8  -  CONSULTA LIBRE
-- ----------------------------------------------------------------------------
-- PREGUNTA DE NEGOCIO:
--   Cuales alojamientos estan bien calificados por los huespedes pero venden
--   pocas noches? Son los candidatos naturales a una campana de promocion:
--   el producto ya es bueno, lo que falta es demanda. Gastar publicidad en un
--   alojamiento mal calificado solo acelera las resenas malas.
--
-- Se compara la posicion del alojamiento en DOS rankings distintos:
--   - por calificacion promedio
--   - por noches vendidas
-- y se muestra la brecha. Brecha grande y positiva = buen producto, mal vendido.
--
-- Se exige un minimo de 25 resenas para que el promedio signifique algo:
-- un alojamiento con una sola resena de 5 estrellas no es "el mejor".
-- ############################################################################
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
