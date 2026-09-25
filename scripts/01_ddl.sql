-- ============================================================================
-- Proyecto Integrador TurismoUQ  |  Script 01 - DDL (creacion de tablas)
-- Universidad del Quindio - Bases de Datos II - codigo 12338 - periodo 2026-2
-- Autor: Daniel Esteban Cifuentes Blandon
-- Motor: Oracle Database 21c Express Edition  |  PDB: XEPDB1
-- Ejecutar conectado como el usuario TURISMOUQ
-- ============================================================================
SET DEFINE OFF;

-- ---------------------------------------------------------------------------
-- 0. Limpieza: permite re-ejecutar este script de arriba a abajo sobre una
--    base que ya tenia objetos. Si la base esta limpia, no hace nada.
-- ---------------------------------------------------------------------------
BEGIN
  FOR t IN (SELECT table_name FROM user_tables) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE "' || t.table_name || '" CASCADE CONSTRAINTS PURGE';
  END LOOP;
END;
/

-- ---------------------------------------------------------------------------
-- 1. MUNICIPIO : los 12 municipios del Quindio
-- ---------------------------------------------------------------------------
CREATE TABLE municipio (
  id_municipio  NUMBER(4)     CONSTRAINT pk_municipio PRIMARY KEY,
  nombre        VARCHAR2(60)  CONSTRAINT nn_mpio_nombre NOT NULL,
  CONSTRAINT uq_mpio_nombre UNIQUE (nombre)
);

-- ---------------------------------------------------------------------------
-- 2. TIPO_ALOJAMIENTO : finca cafetera, hotel, glamping, hostal...
-- ---------------------------------------------------------------------------
CREATE TABLE tipo_alojamiento (
  id_tipo  NUMBER(4)     CONSTRAINT pk_tipo_aloj PRIMARY KEY,
  nombre   VARCHAR2(50)  CONSTRAINT nn_tipo_nombre NOT NULL,
  CONSTRAINT uq_tipo_nombre UNIQUE (nombre)
);

-- ---------------------------------------------------------------------------
-- 3. ALOJAMIENTO : la oferta. Pertenece a un municipio y a un tipo.
-- ---------------------------------------------------------------------------
CREATE TABLE alojamiento (
  id_alojamiento  NUMBER(6)      CONSTRAINT pk_alojamiento PRIMARY KEY,
  nombre          VARCHAR2(120)  CONSTRAINT nn_aloj_nombre NOT NULL,
  id_municipio    NUMBER(4)      CONSTRAINT nn_aloj_mpio   NOT NULL,
  id_tipo         NUMBER(4)      CONSTRAINT nn_aloj_tipo   NOT NULL,
  capacidad_max   NUMBER(4)      CONSTRAINT nn_aloj_cap    NOT NULL,
  CONSTRAINT fk_aloj_municipio FOREIGN KEY (id_municipio) REFERENCES municipio (id_municipio),
  CONSTRAINT fk_aloj_tipo      FOREIGN KEY (id_tipo)      REFERENCES tipo_alojamiento (id_tipo),
  CONSTRAINT ck_aloj_capacidad CHECK (capacidad_max BETWEEN 1 AND 500),
  CONSTRAINT uq_aloj_nombre    UNIQUE (nombre, id_municipio)
);

-- ---------------------------------------------------------------------------
-- 4. HABITACION : unidad rentable dentro de un alojamiento
-- ---------------------------------------------------------------------------
CREATE TABLE habitacion (
  id_habitacion   NUMBER(6)     CONSTRAINT pk_habitacion PRIMARY KEY,
  id_alojamiento  NUMBER(6)     CONSTRAINT nn_hab_aloj   NOT NULL,
  numero          VARCHAR2(10)  CONSTRAINT nn_hab_numero NOT NULL,
  tipo_habitacion VARCHAR2(20)  CONSTRAINT nn_hab_tipo   NOT NULL,
  estado          VARCHAR2(15)  DEFAULT 'DISPONIBLE' CONSTRAINT nn_hab_estado NOT NULL,
  capacidad       NUMBER(2)     DEFAULT 2 CONSTRAINT nn_hab_capacidad NOT NULL,
  CONSTRAINT fk_hab_alojamiento FOREIGN KEY (id_alojamiento) REFERENCES alojamiento (id_alojamiento),
  CONSTRAINT ck_hab_tipo   CHECK (tipo_habitacion IN ('SENCILLA','DOBLE','TRIPLE','SUITE','FAMILIAR')),
  CONSTRAINT ck_hab_estado CHECK (estado IN ('DISPONIBLE','MANTENIMIENTO','INACTIVA')),
  CONSTRAINT ck_hab_cap    CHECK (capacidad BETWEEN 1 AND 12),
  CONSTRAINT uq_hab_numero UNIQUE (id_alojamiento, numero)
);

-- ---------------------------------------------------------------------------
-- 5. TEMPORADA : bloques de fechas ALTA / BAJA. No se traslapan entre si y
--    juntas cubren completo 2024-2026. Esto es lo que permite que una estadia
--    atraviese dos temporadas con tarifas distintas.
-- ---------------------------------------------------------------------------
CREATE TABLE temporada (
  id_temporada  NUMBER(6)     CONSTRAINT pk_temporada PRIMARY KEY,
  nombre        VARCHAR2(60)  CONSTRAINT nn_temp_nombre NOT NULL,
  fecha_inicio  DATE          CONSTRAINT nn_temp_ini    NOT NULL,
  fecha_fin     DATE          CONSTRAINT nn_temp_fin    NOT NULL,
  tipo          VARCHAR2(10)  CONSTRAINT nn_temp_tipo   NOT NULL,
  CONSTRAINT ck_temp_tipo   CHECK (tipo IN ('ALTA','BAJA')),
  CONSTRAINT ck_temp_rango  CHECK (fecha_fin >= fecha_inicio),
  CONSTRAINT uq_temp_nombre UNIQUE (nombre)
);

-- ---------------------------------------------------------------------------
-- 6. TARIFA : precio por noche de una habitacion en una temporada
-- ---------------------------------------------------------------------------
CREATE TABLE tarifa (
  id_tarifa     NUMBER(8)      CONSTRAINT pk_tarifa PRIMARY KEY,
  id_habitacion NUMBER(6)      CONSTRAINT nn_tar_hab   NOT NULL,
  id_temporada  NUMBER(6)      CONSTRAINT nn_tar_temp  NOT NULL,
  valor_noche   NUMBER(12,2)   CONSTRAINT nn_tar_valor NOT NULL,
  CONSTRAINT fk_tar_habitacion FOREIGN KEY (id_habitacion) REFERENCES habitacion (id_habitacion),
  CONSTRAINT fk_tar_temporada  FOREIGN KEY (id_temporada)  REFERENCES temporada (id_temporada),
  CONSTRAINT ck_tar_valor    CHECK (valor_noche > 0),
  CONSTRAINT uq_tar_hab_temp UNIQUE (id_habitacion, id_temporada)
);

-- ---------------------------------------------------------------------------
-- 7. CLIENTE
-- ---------------------------------------------------------------------------
CREATE TABLE cliente (
  id_cliente  NUMBER(8)      CONSTRAINT pk_cliente PRIMARY KEY,
  nombre      VARCHAR2(120)  CONSTRAINT nn_cli_nombre NOT NULL,
  documento   VARCHAR2(20)   CONSTRAINT nn_cli_doc    NOT NULL,
  email       VARCHAR2(150)  CONSTRAINT nn_cli_email  NOT NULL,
  CONSTRAINT uq_cli_documento UNIQUE (documento),
  CONSTRAINT uq_cli_email     UNIQUE (email),
  CONSTRAINT ck_cli_email     CHECK (email LIKE '%@%.%')
);

-- ---------------------------------------------------------------------------
-- 8. RESERVA : cabecera. El detalle de habitaciones va en RESERVA_HABITACION.
-- ---------------------------------------------------------------------------
CREATE TABLE reserva (
  id_reserva      NUMBER(10)    CONSTRAINT pk_reserva PRIMARY KEY,
  id_cliente      NUMBER(8)     CONSTRAINT nn_res_cliente  NOT NULL,
  fecha_checkin   DATE          CONSTRAINT nn_res_checkin  NOT NULL,
  fecha_checkout  DATE          CONSTRAINT nn_res_checkout NOT NULL,
  estado          VARCHAR2(15)  CONSTRAINT nn_res_estado   NOT NULL,
  valor_total     NUMBER(14,2)  DEFAULT 0 CONSTRAINT nn_res_valor NOT NULL,
  CONSTRAINT fk_res_cliente FOREIGN KEY (id_cliente) REFERENCES cliente (id_cliente),
  CONSTRAINT ck_res_fechas  CHECK (fecha_checkout > fecha_checkin),
  CONSTRAINT ck_res_estado  CHECK (estado IN ('PENDIENTE','CONFIRMADA','FINALIZADA','CANCELADA')),
  CONSTRAINT ck_res_valor   CHECK (valor_total >= 0)
) TABLESPACE ts_historico_reservas;

-- ---------------------------------------------------------------------------
-- 9. RESERVA_HABITACION : tabla puente, y el corazon de las dos decisiones
--    de diseno que hay que sustentar.
--
--    DECISION 1 - una reserva toma varias habitaciones:
--      la reserva no apunta a una habitacion; son estas filas las que unen
--      RESERVA con HABITACION. Una reserva con 3 habitaciones son 3 grupos
--      de filas aqui.
--
--    DECISION 2 - una estadia atraviesa dos temporadas con tarifas distintas:
--      la PK incluye ID_TEMPORADA. Una estadia del 13 al 18 de enero parte
--      el 15 de enero (fin de "Alta Enero", inicio de "Baja I") y genera DOS
--      filas para la misma habitacion: 2 noches a tarifa alta y 3 a tarifa
--      baja. El valor de la estadia es SUM(noches * valor_noche_aplicado),
--      sin necesidad de recalcular nada.
--
--    VALOR_NOCHE_APLICADO se copia desde TARIFA en el momento de reservar y
--    ya no se vuelve a tocar: es precio historico. Si manana suben la tarifa,
--    las reservas viejas conservan lo que el cliente realmente pago.
-- ---------------------------------------------------------------------------
CREATE TABLE reserva_habitacion (
  id_reserva           NUMBER(10),
  id_habitacion        NUMBER(6),
  id_temporada         NUMBER(6),
  noches               NUMBER(3)    CONSTRAINT nn_rh_noches NOT NULL,
  valor_noche_aplicado NUMBER(12,2) CONSTRAINT nn_rh_valor  NOT NULL,
  CONSTRAINT pk_reserva_habitacion PRIMARY KEY (id_reserva, id_habitacion, id_temporada),
  CONSTRAINT fk_rh_reserva    FOREIGN KEY (id_reserva)    REFERENCES reserva (id_reserva),
  CONSTRAINT fk_rh_habitacion FOREIGN KEY (id_habitacion) REFERENCES habitacion (id_habitacion),
  CONSTRAINT fk_rh_temporada  FOREIGN KEY (id_temporada)  REFERENCES temporada (id_temporada),
  CONSTRAINT ck_rh_noches CHECK (noches > 0),
  CONSTRAINT ck_rh_valor  CHECK (valor_noche_aplicado > 0)
) TABLESPACE ts_historico_reservas;

-- ---------------------------------------------------------------------------
-- 10. SERVICIO : servicios complementarios que ofrece cada alojamiento
-- ---------------------------------------------------------------------------
CREATE TABLE servicio (
  id_servicio     NUMBER(6)     CONSTRAINT pk_servicio PRIMARY KEY,
  id_alojamiento  NUMBER(6)     CONSTRAINT nn_serv_aloj   NOT NULL,
  nombre          VARCHAR2(80)  CONSTRAINT nn_serv_nombre NOT NULL,
  valor           NUMBER(12,2)  CONSTRAINT nn_serv_valor  NOT NULL,
  CONSTRAINT fk_serv_alojamiento FOREIGN KEY (id_alojamiento) REFERENCES alojamiento (id_alojamiento),
  CONSTRAINT ck_serv_valor  CHECK (valor >= 0),
  CONSTRAINT uq_serv_nombre UNIQUE (id_alojamiento, nombre)
);

-- ---------------------------------------------------------------------------
-- 11. RESERVA_SERVICIO : servicios consumidos en una reserva
-- ---------------------------------------------------------------------------
CREATE TABLE reserva_servicio (
  id_reserva_servicio NUMBER(10)   CONSTRAINT pk_reserva_servicio PRIMARY KEY,
  id_reserva          NUMBER(10)   CONSTRAINT nn_rs_reserva  NOT NULL,
  id_servicio         NUMBER(6)    CONSTRAINT nn_rs_servicio NOT NULL,
  cantidad            NUMBER(4)    CONSTRAINT nn_rs_cantidad NOT NULL,
  valor_total         NUMBER(14,2) CONSTRAINT nn_rs_valor    NOT NULL,
  CONSTRAINT fk_rs_reserva  FOREIGN KEY (id_reserva)  REFERENCES reserva (id_reserva),
  CONSTRAINT fk_rs_servicio FOREIGN KEY (id_servicio) REFERENCES servicio (id_servicio),
  CONSTRAINT ck_rs_cantidad CHECK (cantidad > 0),
  CONSTRAINT ck_rs_valor    CHECK (valor_total >= 0)
) TABLESPACE ts_historico_reservas;

-- ---------------------------------------------------------------------------
-- 12. PAGO
-- ---------------------------------------------------------------------------
CREATE TABLE pago (
  id_pago      NUMBER(10)    CONSTRAINT pk_pago PRIMARY KEY,
  id_reserva   NUMBER(10)    CONSTRAINT nn_pago_reserva NOT NULL,
  fecha_pago   DATE          CONSTRAINT nn_pago_fecha   NOT NULL,
  valor        NUMBER(14,2)  CONSTRAINT nn_pago_valor   NOT NULL,
  metodo_pago  VARCHAR2(20)  CONSTRAINT nn_pago_metodo  NOT NULL,
  CONSTRAINT fk_pago_reserva FOREIGN KEY (id_reserva) REFERENCES reserva (id_reserva),
  CONSTRAINT ck_pago_valor  CHECK (valor > 0),
  CONSTRAINT ck_pago_metodo CHECK (metodo_pago IN ('EFECTIVO','TARJETA_CREDITO','TARJETA_DEBITO','PSE','TRANSFERENCIA'))
) TABLESPACE ts_historico_reservas;

-- ---------------------------------------------------------------------------
-- 13. RESENA : una reserva puede tener a lo sumo una resena
-- ---------------------------------------------------------------------------
CREATE TABLE resena (
  id_resena     NUMBER(10)  CONSTRAINT pk_resena PRIMARY KEY,
  id_reserva    NUMBER(10)  CONSTRAINT nn_rsn_reserva NOT NULL,
  id_cliente    NUMBER(8)   CONSTRAINT nn_rsn_cliente NOT NULL,
  calificacion  NUMBER(1)   CONSTRAINT nn_rsn_calif   NOT NULL,
  CONSTRAINT fk_rsn_reserva FOREIGN KEY (id_reserva) REFERENCES reserva (id_reserva),
  CONSTRAINT fk_rsn_cliente FOREIGN KEY (id_cliente) REFERENCES cliente (id_cliente),
  CONSTRAINT ck_rsn_calif   CHECK (calificacion BETWEEN 1 AND 5),
  CONSTRAINT uq_rsn_reserva UNIQUE (id_reserva)
) TABLESPACE ts_historico_reservas;

-- ---------------------------------------------------------------------------
-- 14. USUARIO_SISTEMA : quien opera la plataforma
-- ---------------------------------------------------------------------------
CREATE TABLE usuario_sistema (
  id_usuario      NUMBER(6)     CONSTRAINT pk_usuario PRIMARY KEY,
  username        VARCHAR2(40)  CONSTRAINT nn_usr_username NOT NULL,
  rol             VARCHAR2(30)  CONSTRAINT nn_usr_rol      NOT NULL,
  id_alojamiento  NUMBER(6),
  CONSTRAINT fk_usr_alojamiento FOREIGN KEY (id_alojamiento) REFERENCES alojamiento (id_alojamiento),
  CONSTRAINT uq_usr_username UNIQUE (username),
  CONSTRAINT ck_usr_rol CHECK (rol IN ('RECEPCION','ADMIN_ALOJAMIENTO','GERENTE','AUDITOR'))
);

-- ---------------------------------------------------------------------------
-- Indices sobre las llaves foraneas mas consultadas.
-- Oracle NO crea indice automatico sobre una FK: sin esto, los JOIN de las
-- consultas de analisis harian full table scan.
-- ---------------------------------------------------------------------------
CREATE INDEX ix_aloj_municipio  ON alojamiento (id_municipio);
CREATE INDEX ix_aloj_tipo       ON alojamiento (id_tipo);
CREATE INDEX ix_hab_alojamiento ON habitacion (id_alojamiento);
CREATE INDEX ix_tar_temporada   ON tarifa (id_temporada);
CREATE INDEX ix_res_cliente     ON reserva (id_cliente)            TABLESPACE ts_historico_reservas;
CREATE INDEX ix_res_checkin     ON reserva (fecha_checkin)         TABLESPACE ts_historico_reservas;
CREATE INDEX ix_rh_habitacion   ON reserva_habitacion (id_habitacion) TABLESPACE ts_historico_reservas;
CREATE INDEX ix_rh_temporada    ON reserva_habitacion (id_temporada)  TABLESPACE ts_historico_reservas;
CREATE INDEX ix_serv_aloj       ON servicio (id_alojamiento);
CREATE INDEX ix_rs_reserva      ON reserva_servicio (id_reserva)    TABLESPACE ts_historico_reservas;
CREATE INDEX ix_rs_servicio     ON reserva_servicio (id_servicio)   TABLESPACE ts_historico_reservas;
CREATE INDEX ix_pago_reserva    ON pago (id_reserva)                TABLESPACE ts_historico_reservas;
CREATE INDEX ix_temp_rango      ON temporada (fecha_inicio, fecha_fin);

COMMIT;

PROMPT ==========================================================
PROMPT  DDL ejecutado. Tablas creadas en el esquema TURISMOUQ:
PROMPT ==========================================================
SELECT table_name FROM user_tables ORDER BY table_name;
