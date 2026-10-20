-- TurismoUQ - Script 02: carga de datos con PL/SQL y DBMS_RANDOM
-- 12 municipios, 60 alojamientos, 400 habitaciones, 3000 clientes,
-- 25000 reservas entre 2024 y 2026 y cerca de 40000 lineas de servicios.
-- Ejecutar como TURISMOUQ despues del script 01

SET DEFINE OFF;
SET TIMING ON;
SET SERVEROUTPUT ON;

-- Borra los datos anteriores, de las tablas hijas a las padres
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

-- 1. Municipios del Quindio
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

-- 2. Tipos de alojamiento
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (1, 'Finca Cafetera');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (2, 'Hotel');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (3, 'Glamping');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (4, 'Hostal');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (5, 'Cabana');
INSERT INTO tipo_alojamiento (id_tipo, nombre) VALUES (6, 'Apartamento Turistico');
COMMIT;

-- 3. Alojamientos: 60, cinco por municipio
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

-- 4. Habitaciones: 400
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

-- 5. Temporadas: 7 por ano, de 2024 a 2027, sin cruzarse entre si.
--    2027 cubre las estadias que empiezan en diciembre de 2026 y terminan en enero.
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

-- 6. Tarifas: precio de cada habitacion en cada temporada
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

-- 7. Clientes: 3000
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

-- 8 y 9. Reservas y reserva_habitacion.
--    Se lleva un mapa de ocupacion en memoria y solo se asigna una habitacion
--    si esta libre todas las noches, asi ninguna queda reservada dos veces.
DECLARE
  TYPE t_num  IS TABLE OF NUMBER       INDEX BY PLS_INTEGER;
  TYPE t_dat  IS TABLE OF DATE         INDEX BY PLS_INTEGER;
  TYPE t_txt  IS TABLE OF VARCHAR2(15) INDEX BY PLS_INTEGER;
  TYPE t_bool IS TABLE OF BOOLEAN      INDEX BY PLS_INTEGER;

  c_total   CONSTANT PLS_INTEGER := 25000;
  c_origen  CONSTANT DATE := DATE '2024-01-01';   -- dia 0 del mapa de ocupacion
  c_desde   CONSTANT DATE := DATE '2024-01-01';
  c_hasta   CONSTANT DATE := DATE '2026-12-20';
  c_corte   CONSTANT DATE := DATE '2026-09-22';   -- antes de esta fecha: FINALIZADA

  r_id t_num;  r_cli t_num;  r_in t_dat;  r_out t_dat;  r_est t_txt;

  d_res t_num;  d_hab t_num;  d_tem t_num;  d_noc t_num;  d_val t_num;
  n_det PLS_INTEGER := 0;

  ocupado t_bool;

  hab_de    t_num;
  cant_hab  t_num;                 -- clave = id_alojamiento
  aloj_ids  t_num;                 -- lista de alojamientos existentes
  n_aloj    PLS_INTEGER := 0;

  tem_id   t_num;  tem_ini  t_dat;  tem_fin  t_dat;  n_tem  PLS_INTEGER := 0;
  alta_ini t_dat;  alta_fin t_dat;                   n_alta PLS_INTEGER := 0;

  tarifa_de t_num;

  v_ci      DATE;
  v_co      DATE;
  v_noches  PLS_INTEGER;
  v_pedidas PLS_INTEGER;
  v_aloj    PLS_INTEGER;
  v_inicio  PLS_INTEGER;
  v_hab     PLS_INTEGER;
  v_libre   BOOLEAN;
  v_est     VARCHAR2(15);
  v_r       NUMBER;
  v_noc     NUMBER;
  elegidas  t_num;
  n_eleg    PLS_INTEGER;
  v_sorteos PLS_INTEGER := 0;
  k         PLS_INTEGER;
BEGIN
  -- Habitaciones por alojamiento, temporadas y tarifas en memoria
  FOR h IN (SELECT id_alojamiento, id_habitacion
            FROM   habitacion
            ORDER  BY id_alojamiento, id_habitacion) LOOP
    IF NOT cant_hab.EXISTS(h.id_alojamiento) THEN
      cant_hab(h.id_alojamiento) := 0;
      n_aloj := n_aloj + 1;
      aloj_ids(n_aloj) := h.id_alojamiento;
    END IF;
    cant_hab(h.id_alojamiento) := cant_hab(h.id_alojamiento) + 1;
    hab_de(h.id_alojamiento * 100 + cant_hab(h.id_alojamiento)) := h.id_habitacion;
  END LOOP;

  FOR t IN (SELECT id_temporada, fecha_inicio, fecha_fin, tipo
            FROM   temporada
            ORDER  BY fecha_inicio) LOOP
    n_tem := n_tem + 1;
    tem_id(n_tem)  := t.id_temporada;
    tem_ini(n_tem) := t.fecha_inicio;
    tem_fin(n_tem) := t.fecha_fin;
    IF t.tipo = 'ALTA' AND t.fecha_fin <= DATE '2026-12-31' THEN
      n_alta := n_alta + 1;
      alta_ini(n_alta) := t.fecha_inicio;
      alta_fin(n_alta) := t.fecha_fin;
    END IF;
  END LOOP;

  FOR x IN (SELECT id_habitacion, id_temporada, valor_noche FROM tarifa) LOOP
    tarifa_de(x.id_habitacion * 100 + x.id_temporada) := x.valor_noche;
  END LOOP;

  -- Generar las reservas
  FOR i IN 1 .. c_total LOOP

    LOOP
      v_sorteos := v_sorteos + 1;
      IF v_sorteos > 5000000 THEN
        RAISE_APPLICATION_ERROR(-20900,
          'No se encontraron habitaciones libres para la reserva ' || i);
      END IF;

      -- 45% de las fechas caen en temporada alta
      IF DBMS_RANDOM.VALUE(0, 1) < 0.45 THEN
        k := TRUNC(DBMS_RANDOM.VALUE(1, n_alta + 1));
        v_ci := alta_ini(k) + TRUNC(DBMS_RANDOM.VALUE(0, alta_fin(k) - alta_ini(k) + 1));
      ELSE
        v_ci := c_desde + TRUNC(DBMS_RANDOM.VALUE(0, c_hasta - c_desde + 1));
      END IF;
      v_noches := TRUNC(DBMS_RANDOM.VALUE(1, 8));          -- de 1 a 7 noches
      v_co     := v_ci + v_noches;

      v_r := DBMS_RANDOM.VALUE(0, 1);
      v_pedidas := CASE WHEN v_r < 0.70 THEN 1
                        WHEN v_r < 0.92 THEN 2
                        ELSE                 3
                   END;

      v_aloj   := aloj_ids(TRUNC(DBMS_RANDOM.VALUE(1, n_aloj + 1)));
      v_inicio := TRUNC(DBMS_RANDOM.VALUE(0, cant_hab(v_aloj)));

      -- Buscar habitaciones libres en el alojamiento sorteado
      n_eleg := 0;
      FOR j IN 0 .. cant_hab(v_aloj) - 1 LOOP
        EXIT WHEN n_eleg = v_pedidas;
        v_hab := hab_de(v_aloj * 100 + MOD(v_inicio + j, cant_hab(v_aloj)) + 1);
        v_libre := TRUE;
        FOR d IN 0 .. v_noches - 1 LOOP
          IF ocupado.EXISTS(v_hab * 10000 + (v_ci - c_origen) + d) THEN
            v_libre := FALSE;
            EXIT;
          END IF;
        END LOOP;
        IF v_libre THEN
          n_eleg := n_eleg + 1;
          elegidas(n_eleg) := v_hab;
        END IF;
      END LOOP;

      EXIT WHEN n_eleg = v_pedidas;
    END LOOP;

    v_est := CASE WHEN DBMS_RANDOM.VALUE(0, 1) < 0.08 THEN 'CANCELADA'
                  WHEN v_ci < c_corte                  THEN 'FINALIZADA'
                  ELSE                                      'CONFIRMADA'
             END;

    r_id(i)  := i;
    r_cli(i) := TRUNC(DBMS_RANDOM.VALUE(1, 3001));
    r_in(i)  := v_ci;
    r_out(i) := v_co;
    r_est(i) := v_est;

    -- Marcar las noches ocupadas (una cancelada no ocupa) y partir por temporada
    FOR e IN 1 .. n_eleg LOOP
      IF v_est <> 'CANCELADA' THEN
        FOR d IN 0 .. v_noches - 1 LOOP
          ocupado(elegidas(e) * 10000 + (v_ci - c_origen) + d) := TRUE;
        END LOOP;
      END IF;

      FOR t IN 1 .. n_tem LOOP
        -- noches de la estadia que caen en esta temporada
        v_noc := LEAST(v_co - 1, tem_fin(t)) - GREATEST(v_ci, tem_ini(t)) + 1;
        IF v_noc > 0 THEN
          n_det := n_det + 1;
          d_res(n_det) := i;
          d_hab(n_det) := elegidas(e);
          d_tem(n_det) := tem_id(t);
          d_noc(n_det) := v_noc;
          d_val(n_det) := tarifa_de(elegidas(e) * 100 + tem_id(t));
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  -- Insertar todo de una sola vez
  FORALL i IN 1 .. c_total
    INSERT INTO reserva (id_reserva, id_cliente, fecha_checkin, fecha_checkout, estado, valor_total)
    VALUES (r_id(i), r_cli(i), r_in(i), r_out(i), r_est(i), 0);

  FORALL i IN 1 .. n_det
    INSERT INTO reserva_habitacion (id_reserva, id_habitacion, id_temporada, noches, valor_noche_aplicado)
    VALUES (d_res(i), d_hab(i), d_tem(i), d_noc(i), d_val(i));

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('Reservas insertadas         : ' || c_total);
  DBMS_OUTPUT.PUT_LINE('Filas en RESERVA_HABITACION : ' || n_det);
  DBMS_OUTPUT.PUT_LINE('Sorteos necesarios          : ' || v_sorteos);
END;
/

-- 10. Servicios: 4 por alojamiento
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

-- 11. Servicios consumidos, siempre del alojamiento donde se hospedo
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

-- 12. Valor total de cada reserva = alojamiento + servicios
UPDATE reserva r
SET    valor_total =
         NVL((SELECT SUM(rh.noches * rh.valor_noche_aplicado)
              FROM   reserva_habitacion rh
              WHERE  rh.id_reserva = r.id_reserva), 0)
       + NVL((SELECT SUM(rs.valor_total)
              FROM   reserva_servicio rs
              WHERE  rs.id_reserva = r.id_reserva), 0);
COMMIT;

-- 13. Pagos de las reservas no canceladas
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

-- 14. Resenas del 45% de las reservas finalizadas
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

-- 15. Usuarios del sistema
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

-- 16. Estadisticas para el optimizador
BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS(ownname => USER, cascade => TRUE);
END;
/

SET TIMING OFF;

PROMPT Filas por tabla:
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

PROMPT Reservas solapadas en la misma habitacion (debe dar 0):
WITH estadia AS (
  SELECT DISTINCT rh.id_reserva, rh.id_habitacion,
         r.fecha_checkin AS ci, r.fecha_checkout AS co
  FROM   reserva_habitacion rh
  JOIN   reserva r ON r.id_reserva = rh.id_reserva
  WHERE  r.estado <> 'CANCELADA'
)
SELECT COUNT(*) AS reservas_solapadas
FROM   estadia a
JOIN   estadia b ON b.id_habitacion = a.id_habitacion
                AND a.id_reserva    < b.id_reserva
                AND a.ci < b.co
                AND b.ci < a.co;
