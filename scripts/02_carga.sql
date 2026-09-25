-- ============================================================================
-- Proyecto Integrador TurismoUQ  |  Script 02 - Carga de datos
-- Universidad del Quindio - Bases de Datos II - codigo 12338 - periodo 2026-2
-- Autor: Daniel Esteban Cifuentes Blandon
--
-- Volumen generado (minimo exigido por el enunciado):
--   12 municipios | 60 alojamientos | 400 habitaciones | 3.000 clientes
--   25.000 reservas repartidas en 2024-2026 | 40.000 lineas de servicios
--
-- Los datos se generan con PL/SQL + DBMS_RANDOM. La demanda NO es uniforme:
-- el 45% de las reservas cae dentro de temporada alta, para que las consultas
-- de analisis muestren la estacionalidad real del turismo en el Quindio.
--
-- Ejecutar DESPUES de 01_ddl.sql, conectado como TURISMOUQ.
-- ============================================================================
SET DEFINE OFF;
SET TIMING ON;
SET SERVEROUTPUT ON;

-- ---------------------------------------------------------------------------
-- Borrado en orden inverso a las dependencias (permite re-ejecutar la carga)
-- ---------------------------------------------------------------------------
DELETE FROM resena;
DELETE FROM pago;
DELETE FROM reserva_servicio;
DELETE FROM reserva_habitacion;
DELETE FROM reserva;
DELETE FROM usuario_sistema;
DELETE FROM servicio;
DELETE FROM cliente;
DELETE FROM tarifa;
DELETE FROM temporada;
DELETE FROM habitacion;
DELETE FROM alojamiento;
DELETE FROM tipo_alojamiento;
DELETE FROM municipio;
COMMIT;

-- ---------------------------------------------------------------------------
-- 1. MUNICIPIO : los 12 municipios reales del departamento del Quindio
-- ---------------------------------------------------------------------------
INSERT INTO municipio (id_municipio, nombre) VALUES (1,  'Armenia');
INSERT INTO municipio (id_municipio, nombre) VALUES (2,  'Calarca');
INSERT INTO municipio (id_municipio, nombre) VALUES (3,  'Circasia');
INSERT INTO municipio (id_municipio, nombre) VALUES (4,  'Cordoba');
INSERT INTO municipio (id_municipio, nombre) VALUES (5,  'Filandia');
INSERT INTO municipio (id_municipio, nombre) VALUES (6,  'Genova');
INSERT INTO municipio (id_municipio, nombre) VALUES (7,  'La Tebaida');
INSERT INTO municipio (id_municipio, nombre) VALUES (8,  'Montenegro');
INSERT INTO municipio (id_municipio, nombre) VALUES (9,  'Pijao');
INSERT INTO municipio (id_municipio, nombre) VALUES (10, 'Quimbaya');
INSERT INTO municipio (id_municipio, nombre) VALUES (11, 'Salento');
INSERT INTO municipio (id_municipio, nombre) VALUES (12, 'Buenavista');

-- ---------------------------------------------------------------------------
-- 2. TIPO_ALOJAMIENTO
-- ---------------------------------------------------------------------------
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (1, 'Finca Cafetera');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (2, 'Hotel');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (3, 'Glamping');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (4, 'Hostal');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (5, 'Cabana');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (6, 'Apartamento Turistico');
COMMIT;

-- ---------------------------------------------------------------------------
-- 3. ALOJAMIENTO : 60, cinco por cada municipio
-- ---------------------------------------------------------------------------
INSERT INTO alojamiento (id_alojamiento, nombre, id_municipio, id_tipo, capacidad_max)
SELECT n,
       CASE MOD(ORA_HASH(n, 11), 12)
         WHEN 0  THEN 'El Mirador'
         WHEN 1  THEN 'La Palma Real'
         WHEN 2  THEN 'Villa Carolina'
         WHEN 3  THEN 'El Cafetal'
         WHEN 4  THEN 'Los Guaduales'
         WHEN 5  THEN 'Alto del Cielo'
         WHEN 6  THEN 'Buena Vista'
         WHEN 7  THEN 'El Recreo'
         WHEN 8  THEN 'La Esperanza'
         WHEN 9  THEN 'Camino Real'
         WHEN 10 THEN 'Balcones del Quindio'
         ELSE         'Sendero Verde'
       END || ' ' || TO_CHAR(n),
       MOD(n - 1, 12) + 1,                       -- municipio: 5 alojamientos c/u
       MOD(ORA_HASH(n, 5), 6) + 1,               -- tipo de alojamiento al azar
       TRUNC(DBMS_RANDOM.VALUE(8, 61))           -- capacidad maxima
FROM   (SELECT LEVEL n FROM dual CONNECT BY LEVEL <= 60);

-- ---------------------------------------------------------------------------
-- 4. HABITACION : 400 repartidas entre los 60 alojamientos
-- ---------------------------------------------------------------------------
INSERT INTO habitacion (id_habitacion, id_alojamiento, numero, tipo_habitacion, estado, capacidad)
SELECT n,
       id_alojamiento,
       numero,
       tipo_habitacion,
       CASE WHEN MOD(n, 25) = 0 THEN 'MANTENIMIENTO' ELSE 'DISPONIBLE' END,
       CASE tipo_habitacion
         WHEN 'SENCILLA' THEN 1
         WHEN 'DOBLE'    THEN 2
         WHEN 'TRIPLE'   THEN 3
         WHEN 'SUITE'    THEN 4
         ELSE                 6
       END
FROM (
  SELECT n,
         MOD(n - 1, 60) + 1                                  AS id_alojamiento,
         'H' || LPAD(TO_CHAR(FLOOR((n - 1) / 60) + 1), 2, '0') AS numero,
         CASE MOD(ORA_HASH(n, 99), 10)
           WHEN 0 THEN 'SENCILLA' WHEN 1 THEN 'SENCILLA' WHEN 2 THEN 'SENCILLA'
           WHEN 3 THEN 'DOBLE'    WHEN 4 THEN 'DOBLE'    WHEN 5 THEN 'DOBLE'
           WHEN 6 THEN 'DOBLE'    WHEN 7 THEN 'TRIPLE'   WHEN 8 THEN 'SUITE'
           ELSE        'FAMILIAR'
         END AS tipo_habitacion
  FROM (SELECT LEVEL n FROM dual CONNECT BY LEVEL <= 400)
);
COMMIT;

-- ---------------------------------------------------------------------------
-- 5. TEMPORADA : 7 bloques por ano x 3 anos = 21 temporadas.
--    Los bloques NO se traslapan y entre todos cubren 2024-01-01 a 2026-12-31.
--    Asi una estadia larga puede atravesar dos temporadas distintas.
-- ---------------------------------------------------------------------------
DECLARE
  v_id NUMBER := 0;

  PROCEDURE ins(p_nombre VARCHAR2, p_ini DATE, p_fin DATE, p_tipo VARCHAR2) IS
  BEGIN
    v_id := v_id + 1;
    INSERT INTO temporada (id_temporada, nombre, fecha_inicio, fecha_fin, tipo)
    VALUES (v_id, p_nombre, p_ini, p_fin, p_tipo);
  END;

  FUNCTION d(p_dia VARCHAR2, p_anio NUMBER) RETURN DATE IS
  BEGIN
    RETURN TO_DATE(p_dia || '/' || TO_CHAR(p_anio), 'DD/MM/YYYY');
  END;
BEGIN
  -- 2027 se define para que las estadias que arrancan el 29-31 de diciembre
  -- de 2026 tengan temporada en las noches que caen en enero del ano siguiente.
  FOR y IN 2024 .. 2027 LOOP
    ins('Alta Enero '      || y, d('01/01', y), d('15/01', y), 'ALTA');
    ins('Baja I '          || y, d('16/01', y), d('20/03', y), 'BAJA');
    ins('Semana Santa '    || y, d('21/03', y), d('07/04', y), 'ALTA');
    ins('Baja II '         || y, d('08/04', y), d('14/06', y), 'BAJA');
    ins('Mitad de Ano '    || y, d('15/06', y), d('15/07', y), 'ALTA');
    ins('Baja III '        || y, d('16/07', y), d('14/12', y), 'BAJA');
    ins('Fin de Ano '      || y, d('15/12', y), d('31/12', y), 'ALTA');
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Temporadas creadas: ' || v_id);
END;
/

-- ---------------------------------------------------------------------------
-- 6. TARIFA : precio por noche de cada habitacion en cada temporada
--    (400 habitaciones x 21 temporadas = 8.400 tarifas)
--    El precio depende del tipo de habitacion, del tipo de alojamiento,
--    de si la temporada es ALTA o BAJA, y del ano (inflacion).
-- ---------------------------------------------------------------------------
INSERT INTO tarifa (id_tarifa, id_habitacion, id_temporada, valor_noche)
SELECT ROWNUM,
       id_habitacion,
       id_temporada,
       ROUND(base * f_aloj * f_temp * f_anio / 1000) * 1000
FROM (
  SELECT h.id_habitacion,
         t.id_temporada,
         CASE h.tipo_habitacion
           WHEN 'SENCILLA' THEN  90000
           WHEN 'DOBLE'    THEN 140000
           WHEN 'TRIPLE'   THEN 190000
           WHEN 'SUITE'    THEN 320000
           ELSE                 260000
         END AS base,
         CASE a.id_tipo
           WHEN 1 THEN 1.20   -- finca cafetera
           WHEN 2 THEN 1.00   -- hotel
           WHEN 3 THEN 1.35   -- glamping
           WHEN 4 THEN 0.60   -- hostal
           WHEN 5 THEN 1.10   -- cabana
           ELSE        0.95   -- apartamento turistico
         END AS f_aloj,
         CASE t.tipo WHEN 'ALTA' THEN 1.65 ELSE 1.00 END AS f_temp,
         CASE EXTRACT(YEAR FROM t.fecha_inicio)
           WHEN 2024 THEN 1.00
           WHEN 2025 THEN 1.08
           WHEN 2026 THEN 1.16
           ELSE           1.25
         END AS f_anio
  FROM habitacion h
  JOIN alojamiento a ON a.id_alojamiento = h.id_alojamiento
  CROSS JOIN temporada t
);
COMMIT;

-- ---------------------------------------------------------------------------
-- 7. CLIENTE : 3.000
-- ---------------------------------------------------------------------------
INSERT INTO cliente (id_cliente, nombre, documento, email)
WITH nombres AS (
  SELECT LEVEL p,
         REGEXP_SUBSTR('Juan,Maria,Carlos,Ana,Luis,Sofia,Andres,Camila,Jorge,Valentina,'
                    || 'Felipe,Daniela,Santiago,Laura,Mateo,Isabella,Sebastian,Paula,Ricardo,Natalia',
                       '[^,]+', 1, LEVEL) v
  FROM dual CONNECT BY LEVEL <= 20
),
apellidos AS (
  SELECT LEVEL p,
         REGEXP_SUBSTR('Gomez,Rodriguez,Martinez,Lopez,Garcia,Hernandez,Ramirez,Torres,Vargas,Castro,'
                    || 'Rojas,Moreno,Jimenez,Ruiz,Alvarez,Mejia,Ospina,Zuluaga,Arango,Cardona',
                       '[^,]+', 1, LEVEL) v
  FROM dual CONNECT BY LEVEL <= 20
),
g AS (SELECT LEVEL n FROM dual CONNECT BY LEVEL <= 3000)
SELECT g.n,
       nb.v || ' ' || ap.v,
       TO_CHAR(1000000 + g.n * 7),
       LOWER(nb.v) || '.' || LOWER(ap.v) || g.n || '@correo.com'
FROM   g
JOIN   nombres   nb ON nb.p = MOD(ORA_HASH(g.n,      19), 20) + 1
JOIN   apellidos ap ON ap.p = MOD(ORA_HASH(g.n + 77, 19), 20) + 1;
COMMIT;

-- ---------------------------------------------------------------------------
-- 8. RESERVA : 25.000 entre 2024 y 2026.
--    45% de las reservas se fuerzan dentro de una ventana de temporada ALTA
--    para reproducir la estacionalidad (Semana Santa, mitad de ano, diciembre).
-- ---------------------------------------------------------------------------
DECLARE
  TYPE t_num IS TABLE OF NUMBER       INDEX BY PLS_INTEGER;
  TYPE t_dat IS TABLE OF DATE         INDEX BY PLS_INTEGER;
  TYPE t_txt IS TABLE OF VARCHAR2(15) INDEX BY PLS_INTEGER;

  c_total   CONSTANT PLS_INTEGER := 25000;
  v_id  t_num;  v_cli t_num;  v_in  t_dat;  v_out t_dat;  v_est t_txt;

  v_alta_ini t_dat;  v_alta_fin t_dat;  v_n_alta PLS_INTEGER := 0;
  v_desde  DATE := DATE '2024-01-01';
  v_hasta  DATE := DATE '2026-12-20';
  v_ci     DATE;
  v_noches PLS_INTEGER;
  v_r      NUMBER;
  k        PLS_INTEGER;
BEGIN
  -- Ventanas de temporada alta cargadas en memoria.
  -- Solo hasta 2026: las temporadas de 2027 existen para cubrir las noches de
  -- una estadia que cruza el fin de ano, no para generar reservas nuevas.
  FOR t IN (SELECT fecha_inicio, fecha_fin
            FROM   temporada
            WHERE  tipo = 'ALTA'
              AND  fecha_fin <= DATE '2026-12-31'
            ORDER  BY id_temporada) LOOP
    v_n_alta := v_n_alta + 1;
    v_alta_ini(v_n_alta) := t.fecha_inicio;
    v_alta_fin(v_n_alta) := t.fecha_fin;
  END LOOP;

  FOR i IN 1 .. c_total LOOP
    IF DBMS_RANDOM.VALUE(0, 1) < 0.45 THEN
      k := TRUNC(DBMS_RANDOM.VALUE(1, v_n_alta + 1));
      v_ci := v_alta_ini(k) + TRUNC(DBMS_RANDOM.VALUE(0, v_alta_fin(k) - v_alta_ini(k) + 1));
    ELSE
      v_ci := v_desde + TRUNC(DBMS_RANDOM.VALUE(0, v_hasta - v_desde + 1));
    END IF;

    v_noches := TRUNC(DBMS_RANDOM.VALUE(1, 8));   -- de 1 a 7 noches
    v_r      := DBMS_RANDOM.VALUE(0, 1);

    v_id(i)  := i;
    v_cli(i) := TRUNC(DBMS_RANDOM.VALUE(1, 3001));
    v_in(i)  := v_ci;
    v_out(i) := v_ci + v_noches;
    v_est(i) := CASE WHEN v_r < 0.08              THEN 'CANCELADA'
                     WHEN v_ci < DATE '2026-09-22' THEN 'FINALIZADA'
                     ELSE                               'CONFIRMADA'
                END;
  END LOOP;

  FORALL i IN 1 .. c_total
    INSERT INTO reserva (id_reserva, id_cliente, fecha_checkin, fecha_checkout, estado, valor_total)
    VALUES (v_id(i), v_cli(i), v_in(i), v_out(i), v_est(i), 0);

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Reservas insertadas: ' || c_total);
END;
/

-- ---------------------------------------------------------------------------
-- 9. RESERVA_HABITACION : 1 a 3 habitaciones por reserva, y cada habitacion
--    se parte en tantas filas como temporadas atraviese la estadia.
--
--    Las noches de una estadia son [checkin, checkout-1]: la noche del
--    checkout no se cobra. La interseccion de ese rango con el rango de la
--    temporada da las noches que se cobran a esa tarifa:
--        noches = LEAST(checkout-1, fin_temporada)
--               - GREATEST(checkin,  inicio_temporada) + 1
--    El JOIN solo conserva las temporadas donde esa cuenta da 1 o mas.
-- ---------------------------------------------------------------------------
INSERT INTO reserva_habitacion (id_reserva, id_habitacion, id_temporada, noches, valor_noche_aplicado)
SELECT d.id_reserva,
       d.id_habitacion,
       t.id_temporada,
       LEAST(d.fecha_checkout - 1, t.fecha_fin)
         - GREATEST(d.fecha_checkin, t.fecha_inicio) + 1   AS noches,
       tf.valor_noche
FROM (
  SELECT r.id_reserva,
         MOD(ORA_HASH(r.id_reserva, 399) + (g.lvl - 1), 400) + 1 AS id_habitacion,
         r.fecha_checkin,
         r.fecha_checkout
  FROM   reserva r
  CROSS JOIN (SELECT LEVEL lvl FROM dual CONNECT BY LEVEL <= 3) g
  WHERE  g.lvl = 1
     OR (g.lvl = 2 AND MOD(ORA_HASH(r.id_reserva, 99), 100) < 30)
     OR (g.lvl = 3 AND MOD(ORA_HASH(r.id_reserva, 99), 100) < 8)
) d
JOIN temporada t ON GREATEST(d.fecha_checkin, t.fecha_inicio)
                 <= LEAST(d.fecha_checkout - 1, t.fecha_fin)
JOIN tarifa    tf ON tf.id_habitacion = d.id_habitacion
                 AND tf.id_temporada  = t.id_temporada;
COMMIT;

-- ---------------------------------------------------------------------------
-- 10. SERVICIO : 4 servicios por alojamiento
-- ---------------------------------------------------------------------------
INSERT INTO servicio (id_servicio, id_alojamiento, nombre, valor)
SELECT ROWNUM, id_alojamiento, nombre, valor
FROM (
  SELECT a.id_alojamiento,
         s.v AS nombre,
         ROUND(s.base * DBMS_RANDOM.VALUE(0.85, 1.25) / 1000) * 1000 AS valor
  FROM alojamiento a
  JOIN (
    SELECT 1 p, 'Desayuno tipico'        v,  18000 base FROM dual UNION ALL
    SELECT 2,   'Tour del cafe',             65000      FROM dual UNION ALL
    SELECT 3,   'Cabalgata',                 80000      FROM dual UNION ALL
    SELECT 4,   'Transporte aeropuerto',     90000      FROM dual UNION ALL
    SELECT 5,   'Spa y masajes',            120000      FROM dual UNION ALL
    SELECT 6,   'Parrilla privada',         150000      FROM dual UNION ALL
    SELECT 7,   'Avistamiento de aves',      70000      FROM dual UNION ALL
    SELECT 8,   'Alquiler de bicicletas',    35000      FROM dual
  ) s ON MOD(a.id_alojamiento + s.p, 2) = 0
);
COMMIT;

-- ---------------------------------------------------------------------------
-- 11. RESERVA_SERVICIO : 40.000 lineas.
--     El servicio consumido siempre pertenece al alojamiento donde se hospedo.
-- ---------------------------------------------------------------------------
INSERT INTO reserva_servicio (id_reserva_servicio, id_reserva, id_servicio, cantidad, valor_total)
WITH alojamiento_de_reserva AS (
  SELECT rh.id_reserva, h.id_alojamiento,
         ROW_NUMBER() OVER (PARTITION BY rh.id_reserva ORDER BY rh.id_habitacion) rn
  FROM   reserva_habitacion rh
  JOIN   habitacion h ON h.id_habitacion = rh.id_habitacion
),
serv AS (
  SELECT s.id_servicio, s.id_alojamiento, s.valor,
         ROW_NUMBER() OVER (PARTITION BY s.id_alojamiento ORDER BY s.id_servicio) rn,
         COUNT(*)     OVER (PARTITION BY s.id_alojamiento)                        cnt
  FROM   servicio s
),
detalle AS (
  SELECT u.id_reserva,
         sv.id_servicio,
         sv.valor,
         TRUNC(DBMS_RANDOM.VALUE(1, 5)) AS cantidad
  FROM   alojamiento_de_reserva u
  CROSS JOIN (SELECT LEVEL lvl FROM dual CONNECT BY LEVEL <= 2) g
  JOIN   serv sv ON sv.id_alojamiento = u.id_alojamiento
                AND sv.rn = MOD(ORA_HASH(u.id_reserva * 10 + g.lvl, 999), sv.cnt) + 1
  WHERE  u.rn = 1
    AND (g.lvl = 1 OR MOD(ORA_HASH(u.id_reserva, 99), 100) < 60)
)
SELECT ROWNUM, id_reserva, id_servicio, cantidad, cantidad * valor
FROM   detalle;
COMMIT;

-- ---------------------------------------------------------------------------
-- 12. Consolidar RESERVA.valor_total = alojamiento + servicios
-- ---------------------------------------------------------------------------
UPDATE reserva r
SET    valor_total =
         NVL((SELECT SUM(rh.noches * rh.valor_noche_aplicado)
              FROM   reserva_habitacion rh
              WHERE  rh.id_reserva = r.id_reserva), 0)
       + NVL((SELECT SUM(rs.valor_total)
              FROM   reserva_servicio rs
              WHERE  rs.id_reserva = r.id_reserva), 0);
COMMIT;

-- ---------------------------------------------------------------------------
-- 13. PAGO : toda reserva no cancelada queda pagada
-- ---------------------------------------------------------------------------
INSERT INTO pago (id_pago, id_reserva, fecha_pago, valor, metodo_pago)
SELECT ROWNUM, id_reserva, fecha_pago, valor, metodo_pago
FROM (
  SELECT r.id_reserva,
         r.fecha_checkin - TRUNC(DBMS_RANDOM.VALUE(0, 21)) AS fecha_pago,
         r.valor_total                                      AS valor,
         CASE MOD(ORA_HASH(r.id_reserva, 99), 5)
           WHEN 0 THEN 'EFECTIVO'
           WHEN 1 THEN 'TARJETA_CREDITO'
           WHEN 2 THEN 'TARJETA_DEBITO'
           WHEN 3 THEN 'PSE'
           ELSE        'TRANSFERENCIA'
         END AS metodo_pago
  FROM   reserva r
  WHERE  r.estado <> 'CANCELADA'
    AND  r.valor_total > 0
);
COMMIT;

-- ---------------------------------------------------------------------------
-- 14. RESENA : el 45% de las reservas finalizadas deja calificacion
-- ---------------------------------------------------------------------------
INSERT INTO resena (id_resena, id_reserva, id_cliente, calificacion)
SELECT ROWNUM, id_reserva, id_cliente, calificacion
FROM (
  SELECT r.id_reserva,
         r.id_cliente,
         CASE
           WHEN MOD(ORA_HASH(r.id_reserva + 7, 999), 100) < 50 THEN 5
           WHEN MOD(ORA_HASH(r.id_reserva + 7, 999), 100) < 78 THEN 4
           WHEN MOD(ORA_HASH(r.id_reserva + 7, 999), 100) < 92 THEN 3
           WHEN MOD(ORA_HASH(r.id_reserva + 7, 999), 100) < 98 THEN 2
           ELSE 1
         END AS calificacion
  FROM   reserva r
  WHERE  r.estado = 'FINALIZADA'
    AND  MOD(ORA_HASH(r.id_reserva, 99), 100) < 45
);
COMMIT;

-- ---------------------------------------------------------------------------
-- 15. USUARIO_SISTEMA : recepcion y administrador por alojamiento,
--     mas gerentes y auditores corporativos (sin alojamiento asignado)
-- ---------------------------------------------------------------------------
INSERT INTO usuario_sistema (id_usuario, username, rol, id_alojamiento)
SELECT ROWNUM, username, rol, id_alojamiento
FROM (
  SELECT 'recep'   || LPAD(TO_CHAR(id_alojamiento), 3, '0') AS username,
         'RECEPCION'                                        AS rol,
         id_alojamiento
  FROM   alojamiento
  UNION ALL
  SELECT 'admin'   || LPAD(TO_CHAR(id_alojamiento), 3, '0'),
         'ADMIN_ALOJAMIENTO',
         id_alojamiento
  FROM   alojamiento
  UNION ALL
  SELECT 'gerente' || TO_CHAR(LEVEL), 'GERENTE', CAST(NULL AS NUMBER(6))
  FROM   dual CONNECT BY LEVEL <= 4
  UNION ALL
  SELECT 'auditor' || TO_CHAR(LEVEL), 'AUDITOR', CAST(NULL AS NUMBER(6))
  FROM   dual CONNECT BY LEVEL <= 2
);
COMMIT;

-- ---------------------------------------------------------------------------
-- 16. Estadisticas para el optimizador.
--     Sin esto Oracle no sabe cuantas filas hay y elige planes malos.
-- ---------------------------------------------------------------------------
BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS(ownname => USER, cascade => TRUE);
END;
/

SET TIMING OFF;
PROMPT
PROMPT ==========================================================
PROMPT  CARGA TERMINADA - volumen por tabla
PROMPT ==========================================================
SELECT 'MUNICIPIO'          AS tabla, COUNT(*) AS filas FROM municipio
UNION ALL SELECT 'TIPO_ALOJAMIENTO',   COUNT(*) FROM tipo_alojamiento
UNION ALL SELECT 'ALOJAMIENTO',        COUNT(*) FROM alojamiento
UNION ALL SELECT 'HABITACION',         COUNT(*) FROM habitacion
UNION ALL SELECT 'TEMPORADA',          COUNT(*) FROM temporada
UNION ALL SELECT 'TARIFA',             COUNT(*) FROM tarifa
UNION ALL SELECT 'CLIENTE',            COUNT(*) FROM cliente
UNION ALL SELECT 'RESERVA',            COUNT(*) FROM reserva
UNION ALL SELECT 'RESERVA_HABITACION', COUNT(*) FROM reserva_habitacion
UNION ALL SELECT 'SERVICIO',           COUNT(*) FROM servicio
UNION ALL SELECT 'RESERVA_SERVICIO',   COUNT(*) FROM reserva_servicio
UNION ALL SELECT 'PAGO',               COUNT(*) FROM pago
UNION ALL SELECT 'RESENA',             COUNT(*) FROM resena
UNION ALL SELECT 'USUARIO_SISTEMA',    COUNT(*) FROM usuario_sistema;
