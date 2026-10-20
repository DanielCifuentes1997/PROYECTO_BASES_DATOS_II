-- TurismoUQ - Script 04: objetos de apoyo de la Entrega 2
-- Numero de huespedes en la reserva, secuencias y las tablas de auditoria de
-- tarifas y de liquidacion mensual.
-- Ejecutar como TURISMOUQ despues del script 03

SET DEFINE OFF;
SET SERVEROUTPUT ON;

-- Borra lo que crea el script, para poder ejecutarlo de nuevo
BEGIN
  FOR s IN (SELECT sequence_name FROM user_sequences
            WHERE  sequence_name IN ('SEQ_RESERVA', 'SEQ_CLIENTE', 'SEQ_RESERVA_SERVICIO',
                                     'SEQ_PAGO', 'SEQ_AUDITORIA_TARIFA')) LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.sequence_name;
  END LOOP;

  FOR t IN (SELECT table_name FROM user_tables
            WHERE  table_name IN ('AUDITORIA_TARIFA', 'LIQUIDACION_MENSUAL')) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
  END LOOP;

  FOR c IN (SELECT column_name FROM user_tab_columns
            WHERE  table_name = 'RESERVA' AND column_name = 'NUM_HUESPEDES') LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE reserva DROP COLUMN num_huespedes';
  END LOOP;
END;
/

-- Numero de huespedes de cada reserva, para poder validar la capacidad.
-- Toda reserva tiene al menos un huesped, por eso el valor por defecto es 1.
ALTER TABLE reserva ADD num_huespedes NUMBER(3) DEFAULT 1
  CONSTRAINT nn_res_huespedes NOT NULL
  CONSTRAINT ck_res_huespedes CHECK (num_huespedes > 0);

-- A las reservas que ya existen se les asigna un numero de huespedes entre 1
-- y la capacidad total de sus habitaciones, para que tambien cumplan la regla.
UPDATE reserva r
SET    num_huespedes = (
         SELECT NVL(TRUNC(DBMS_RANDOM.VALUE(1, SUM(h.capacidad) + 1)), 1)
         FROM   habitacion h
         WHERE  h.id_habitacion IN (SELECT rh.id_habitacion
                                    FROM   reserva_habitacion rh
                                    WHERE  rh.id_reserva = r.id_reserva));
COMMIT;

-- Secuencias para los registros nuevos que crea el paquete: reservas,
-- clientes, servicios consumidos y pagos. Cada una arranca despues del ultimo
-- id cargado; como START WITH solo acepta un numero fijo, se arma con
-- EXECUTE IMMEDIATE. NOCACHE para que los numeros salgan consecutivos.
DECLARE
  PROCEDURE crear_secuencia(p_secuencia VARCHAR2, p_tabla VARCHAR2, p_columna VARCHAR2) IS
    v_inicio NUMBER;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT NVL(MAX(' || p_columna || '), 0) + 1 FROM ' || p_tabla
      INTO v_inicio;
    EXECUTE IMMEDIATE 'CREATE SEQUENCE ' || p_secuencia || ' START WITH ' || v_inicio
                   || ' INCREMENT BY 1 NOCACHE';
    DBMS_OUTPUT.PUT_LINE(p_secuencia || ' creada, arranca en ' || v_inicio);
  END;
BEGIN
  crear_secuencia('seq_reserva',          'reserva',          'id_reserva');
  crear_secuencia('seq_cliente',          'cliente',          'id_cliente');
  crear_secuencia('seq_reserva_servicio', 'reserva_servicio', 'id_reserva_servicio');
  crear_secuencia('seq_pago',             'pago',             'id_pago');
END;
/

-- Secuencia para los registros de auditoria
CREATE SEQUENCE seq_auditoria_tarifa START WITH 1 INCREMENT BY 1 NOCACHE;

-- Auditoria de cambios en TARIFA: quien, cuando, valor anterior y nuevo.
-- No tiene llave foranea a TARIFA para que el historial no se pierda
-- si la tarifa se borra.
CREATE TABLE auditoria_tarifa (
  id_auditoria    NUMBER(10)     CONSTRAINT pk_auditoria_tarifa PRIMARY KEY,
  id_tarifa       NUMBER(8)      CONSTRAINT nn_aud_tarifa      NOT NULL,
  id_habitacion   NUMBER(6)      CONSTRAINT nn_aud_habitacion  NOT NULL,
  id_temporada    NUMBER(6)      CONSTRAINT nn_aud_temporada   NOT NULL,
  operacion       VARCHAR2(6)    CONSTRAINT nn_aud_operacion   NOT NULL,
  valor_anterior  NUMBER(12,2),
  valor_nuevo     NUMBER(12,2),
  usuario_bd      VARCHAR2(128)  DEFAULT USER
                                 CONSTRAINT nn_aud_usuario_bd  NOT NULL,
  usuario_so      VARCHAR2(128)  DEFAULT SYS_CONTEXT('USERENV', 'OS_USER'),
  equipo          VARCHAR2(128)  DEFAULT SYS_CONTEXT('USERENV', 'HOST'),
  fecha_cambio    TIMESTAMP      DEFAULT SYSTIMESTAMP
                                 CONSTRAINT nn_aud_fecha       NOT NULL,
  CONSTRAINT ck_aud_operacion CHECK (operacion IN ('INSERT', 'UPDATE', 'DELETE')),
  CONSTRAINT ck_aud_valores CHECK (
       (operacion = 'INSERT' AND valor_anterior IS NULL     AND valor_nuevo IS NOT NULL)
    OR (operacion = 'UPDATE' AND valor_anterior IS NOT NULL AND valor_nuevo IS NOT NULL)
    OR (operacion = 'DELETE' AND valor_anterior IS NOT NULL AND valor_nuevo IS NULL)
  )
);

CREATE INDEX ix_aud_tarifa_fecha ON auditoria_tarifa (id_tarifa, fecha_cambio);

-- Liquidacion mensual por alojamiento: ingresos, comision de la plataforma
-- y valor a pagar. La llave (alojamiento, periodo) impide liquidar dos veces
-- el mismo mes, y ck_liq_cuadre obliga a que las cuentas cuadren.
CREATE TABLE liquidacion_mensual (
  id_alojamiento       NUMBER(6),
  periodo              DATE,
  reservas             NUMBER(6)     CONSTRAINT nn_liq_reservas    NOT NULL,
  noches_vendidas      NUMBER(8)     CONSTRAINT nn_liq_noches      NOT NULL,
  ingreso_alojamiento  NUMBER(14,2)  CONSTRAINT nn_liq_ing_aloj    NOT NULL,
  ingreso_servicios    NUMBER(14,2)  CONSTRAINT nn_liq_ing_serv    NOT NULL,
  porcentaje_comision  NUMBER(5,2)   CONSTRAINT nn_liq_pct         NOT NULL,
  valor_comision       NUMBER(14,2)  CONSTRAINT nn_liq_comision    NOT NULL,
  valor_a_pagar        NUMBER(14,2)  CONSTRAINT nn_liq_pagar       NOT NULL,
  fecha_liquidacion    DATE          DEFAULT SYSDATE
                                     CONSTRAINT nn_liq_fecha       NOT NULL,
  CONSTRAINT pk_liquidacion_mensual PRIMARY KEY (id_alojamiento, periodo),
  CONSTRAINT fk_liq_alojamiento FOREIGN KEY (id_alojamiento)
             REFERENCES alojamiento (id_alojamiento),
  CONSTRAINT ck_liq_periodo  CHECK (periodo = TRUNC(periodo, 'MM')),
  CONSTRAINT ck_liq_positivos CHECK (reservas >= 0 AND noches_vendidas >= 0
                                     AND ingreso_alojamiento >= 0
                                     AND ingreso_servicios   >= 0
                                     AND valor_comision      >= 0
                                     AND valor_a_pagar       >= 0),
  CONSTRAINT ck_liq_pct      CHECK (porcentaje_comision BETWEEN 0 AND 100),
  CONSTRAINT ck_liq_cuadre   CHECK (valor_a_pagar = ingreso_alojamiento
                                                  + ingreso_servicios
                                                  - valor_comision)
);

SET LINESIZE 120;
SET PAGESIZE 50;
SET TAB OFF;
COLUMN objeto FORMAT A24
COLUMN tipo   FORMAT A10
COLUMN detalle FORMAT A50

PROMPT Objetos creados:
SELECT sequence_name AS objeto,
       'SECUENCIA'   AS tipo,
       'proximo valor: ' || last_number AS detalle
FROM   user_sequences
WHERE  sequence_name IN ('SEQ_RESERVA', 'SEQ_CLIENTE', 'SEQ_RESERVA_SERVICIO',
                         'SEQ_PAGO', 'SEQ_AUDITORIA_TARIFA')
UNION ALL
SELECT t.table_name,
       'TABLA',
       COUNT(c.column_name) || ' columnas, '
         || (SELECT COUNT(*) FROM user_constraints k
             WHERE k.table_name = t.table_name) || ' restricciones'
FROM   user_tables t
JOIN   user_tab_columns c ON c.table_name = t.table_name
WHERE  t.table_name IN ('AUDITORIA_TARIFA', 'LIQUIDACION_MENSUAL')
GROUP  BY t.table_name
ORDER  BY 2, 1;

PROMPT Reservas con mas huespedes que la capacidad de sus habitaciones (debe dar 0):
SELECT COUNT(*) AS reservas_sobre_capacidad
FROM   reserva r
WHERE  r.num_huespedes > (SELECT SUM(h.capacidad)
                          FROM   habitacion h
                          WHERE  h.id_habitacion IN (SELECT rh.id_habitacion
                                                     FROM   reserva_habitacion rh
                                                     WHERE  rh.id_reserva = r.id_reserva));
