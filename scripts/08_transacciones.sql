-- TurismoUQ - Script 08: transacciones (Entrega 3)
-- Reserva y pago en una sola transaccion atomica, SAVEPOINT con rollback
-- parcial y una bitacora de errores con transaccion autonoma.
-- Ejecutar como TURISMOUQ despues del script 07

SET DEFINE OFF;
SET SERVEROUTPUT ON;

-- Borra lo que crea el script, para poder ejecutarlo de nuevo
BEGIN
  FOR s IN (SELECT sequence_name FROM user_sequences
            WHERE  sequence_name = 'SEQ_LOG_ERROR') LOOP
    EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.sequence_name;
  END LOOP;

  FOR t IN (SELECT table_name FROM user_tables
            WHERE  table_name = 'LOG_ERRORES_RESERVA') LOOP
    EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
  END LOOP;
END;
/

-- Bitacora de intentos fallidos. No tiene llaves foraneas: tiene que poder
-- guardar intentos con un cliente o una habitacion que no existen.
CREATE SEQUENCE seq_log_error START WITH 1 INCREMENT BY 1 NOCACHE;

CREATE TABLE log_errores_reserva (
  id_log         NUMBER(10)     CONSTRAINT pk_log_errores_reserva PRIMARY KEY,
  operacion      VARCHAR2(30)   CONSTRAINT nn_log_operacion NOT NULL,
  id_cliente     NUMBER(8),
  id_habitacion  NUMBER(6),
  fecha_in       DATE,
  fecha_out      DATE,
  codigo_error   NUMBER(6)      CONSTRAINT nn_log_codigo    NOT NULL,
  mensaje        VARCHAR2(400)  CONSTRAINT nn_log_mensaje   NOT NULL,
  usuario_bd     VARCHAR2(128)  DEFAULT USER
                                CONSTRAINT nn_log_usuario   NOT NULL,
  fecha_error    TIMESTAMP      DEFAULT SYSTIMESTAMP
                                CONSTRAINT nn_log_fecha     NOT NULL
);


-- Especificacion del paquete de la Entrega 3
CREATE OR REPLACE PACKAGE pkg_transacciones IS

  -- Guarda un intento fallido en la bitacora. Es una transaccion autonoma:
  -- su COMMIT no confirma ni deshace nada de la transaccion que la llamo.
  PROCEDURE sp_registrar_error (
    p_operacion      IN log_errores_reserva.operacion%TYPE,
    p_id_cliente     IN log_errores_reserva.id_cliente%TYPE,
    p_id_habitacion  IN log_errores_reserva.id_habitacion%TYPE,
    p_fecha_in       IN log_errores_reserva.fecha_in%TYPE,
    p_fecha_out      IN log_errores_reserva.fecha_out%TYPE,
    p_codigo         IN log_errores_reserva.codigo_error%TYPE,
    p_mensaje        IN log_errores_reserva.mensaje%TYPE
  );

  -- Registra la reserva, un servicio opcional de bienvenida y el pago en una
  -- sola transaccion. Devuelve el numero de la reserva en p_id_reserva.
  PROCEDURE sp_reservar_y_pagar (
    p_id_cliente     IN  cliente.id_cliente%TYPE,
    p_id_habitacion  IN  habitacion.id_habitacion%TYPE,
    p_fecha_in       IN  reserva.fecha_checkin%TYPE,
    p_fecha_out      IN  reserva.fecha_checkout%TYPE,
    p_num_huespedes  IN  reserva.num_huespedes%TYPE,
    p_metodo_pago    IN  pago.metodo_pago%TYPE,
    p_id_servicio    IN  servicio.id_servicio%TYPE DEFAULT NULL,
    p_cantidad       IN  reserva_servicio.cantidad%TYPE DEFAULT 1,
    p_id_reserva     OUT reserva.id_reserva%TYPE
  );

END pkg_transacciones;
/
SHOW ERRORS PACKAGE pkg_transacciones


CREATE OR REPLACE PACKAGE BODY pkg_transacciones IS

  -- sp_registrar_error
  -- Si se escribiera en la bitacora dentro de la misma transaccion de la
  -- reserva, el ROLLBACK que deshace la reserva tambien borraria el registro
  -- del error. Con PRAGMA AUTONOMOUS_TRANSACTION la insercion vive en una
  -- transaccion aparte y su COMMIT la deja guardada pase lo que pase.
  PROCEDURE sp_registrar_error (
    p_operacion      IN log_errores_reserva.operacion%TYPE,
    p_id_cliente     IN log_errores_reserva.id_cliente%TYPE,
    p_id_habitacion  IN log_errores_reserva.id_habitacion%TYPE,
    p_fecha_in       IN log_errores_reserva.fecha_in%TYPE,
    p_fecha_out      IN log_errores_reserva.fecha_out%TYPE,
    p_codigo         IN log_errores_reserva.codigo_error%TYPE,
    p_mensaje        IN log_errores_reserva.mensaje%TYPE
  )
  IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO log_errores_reserva (id_log, operacion, id_cliente, id_habitacion,
                                     fecha_in, fecha_out, codigo_error, mensaje)
    VALUES (seq_log_error.NEXTVAL, p_operacion, p_id_cliente, p_id_habitacion,
            p_fecha_in, p_fecha_out, p_codigo, SUBSTR(p_mensaje, 1, 400));

    COMMIT;
  END sp_registrar_error;


  -- sp_reservar_y_pagar
  -- 1. Bloquea la habitacion con SELECT ... FOR UPDATE y valida.
  -- 2. Registra la reserva y marca el SAVEPOINT sp_reserva_registrada.
  -- 3. Si se pidio un servicio de bienvenida lo carga. Si el servicio falla,
  --    ROLLBACK TO sp_reserva_registrada: se deshace solo el servicio y la
  --    reserva sigue (rollback parcial).
  -- 4. Registra el pago por el valor total y confirma todo con COMMIT.
  -- Si falla la reserva o el pago, ROLLBACK de todo: no puede quedar una
  -- reserva sin pago ni un pago sin reserva.
  PROCEDURE sp_reservar_y_pagar (
    p_id_cliente     IN  cliente.id_cliente%TYPE,
    p_id_habitacion  IN  habitacion.id_habitacion%TYPE,
    p_fecha_in       IN  reserva.fecha_checkin%TYPE,
    p_fecha_out      IN  reserva.fecha_checkout%TYPE,
    p_num_huespedes  IN  reserva.num_huespedes%TYPE,
    p_metodo_pago    IN  pago.metodo_pago%TYPE,
    p_id_servicio    IN  servicio.id_servicio%TYPE DEFAULT NULL,
    p_cantidad       IN  reserva_servicio.cantidad%TYPE DEFAULT 1,
    p_id_reserva     OUT reserva.id_reserva%TYPE
  )
  IS
    e_pago_invalido  EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_pago_invalido, -2290);   -- violacion de un CHECK

    v_entrada         DATE := TRUNC(p_fecha_in);
    v_salida          DATE := TRUNC(p_fecha_out);
    v_existe          NUMBER;
    v_estado          habitacion.estado%TYPE;
    v_capacidad       habitacion.capacidad%TYPE;
    v_aloj_habitacion habitacion.id_alojamiento%TYPE;
    v_valor_servicio  servicio.valor%TYPE;
    v_aloj_servicio   servicio.id_alojamiento%TYPE;
    v_total           reserva.valor_total%TYPE;
    v_codigo          NUMBER;
    v_mensaje         VARCHAR2(400);
  BEGIN
    -- 1. Validaciones
    IF v_entrada IS NULL OR v_salida IS NULL OR v_salida <= v_entrada THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_fechas,
        'La fecha de salida debe ser posterior a la fecha de entrada.');
    END IF;

    IF v_entrada < TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_fechas,
        'No se puede reservar con fecha de entrada en el pasado ('
        || TO_CHAR(v_entrada, 'DD/MM/YYYY') || ').');
    END IF;

    SELECT COUNT(*) INTO v_existe FROM cliente WHERE id_cliente = p_id_cliente;
    IF v_existe = 0 THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_cliente,
        'El cliente ' || p_id_cliente || ' no existe.');
    END IF;

    -- La habitacion se lee con FOR UPDATE: queda bloqueada hasta el COMMIT o
    -- el ROLLBACK, asi nadie mas puede reservarla al mismo tiempo.
    BEGIN
      SELECT estado, capacidad, id_alojamiento
      INTO   v_estado, v_capacidad, v_aloj_habitacion
      FROM   habitacion
      WHERE  id_habitacion = p_id_habitacion
      FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_habitacion,
          'La habitacion ' || p_id_habitacion || ' no existe.');
    END;

    IF v_estado <> 'DISPONIBLE' THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_no_disponible,
        'La habitacion ' || p_id_habitacion || ' no se puede reservar, esta en '
        || v_estado || '.');
    END IF;

    IF p_num_huespedes IS NULL OR p_num_huespedes < 1 OR p_num_huespedes > v_capacidad THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_capacidad,
        'La habitacion ' || p_id_habitacion || ' es para ' || v_capacidad
        || ' personas y se pidio para ' || p_num_huespedes || '.');
    END IF;

    IF NOT pkg_turismouq.fn_habitacion_disponible(p_id_habitacion, v_entrada, v_salida) THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_no_disponible,
        'La habitacion ' || p_id_habitacion || ' ya esta reservada entre el '
        || TO_CHAR(v_entrada, 'DD/MM/YYYY') || ' y el '
        || TO_CHAR(v_salida, 'DD/MM/YYYY') || '.');
    END IF;

    -- 2. Reserva y su detalle por temporada
    p_id_reserva := seq_reserva.NEXTVAL;

    INSERT INTO reserva (id_reserva, id_cliente, fecha_checkin, fecha_checkout,
                         estado, valor_total, num_huespedes)
    VALUES (p_id_reserva, p_id_cliente, v_entrada, v_salida, 'CONFIRMADA',
            pkg_turismouq.fn_valor_estadia(p_id_habitacion, v_entrada, v_salida),
            p_num_huespedes);

    FOR r_tramo IN (SELECT t.id_temporada,
                           tf.valor_noche,
                           LEAST(v_salida - 1, t.fecha_fin)
                             - GREATEST(v_entrada, t.fecha_inicio) + 1 AS noches
                    FROM   temporada t
                    JOIN   tarifa tf ON tf.id_temporada  = t.id_temporada
                                    AND tf.id_habitacion = p_id_habitacion
                    WHERE  t.fecha_inicio <= v_salida - 1
                      AND  t.fecha_fin    >= v_entrada) LOOP
      INSERT INTO reserva_habitacion (id_reserva, id_habitacion, id_temporada,
                                      noches, valor_noche_aplicado)
      VALUES (p_id_reserva, p_id_habitacion, r_tramo.id_temporada,
              r_tramo.noches, r_tramo.valor_noche);
    END LOOP;

    SAVEPOINT sp_reserva_registrada;
    DBMS_OUTPUT.PUT_LINE('1. Reserva ' || p_id_reserva || ' registrada (SAVEPOINT sp_reserva_registrada).');

    -- 3. Servicio de bienvenida (opcional). Si falla no se pierde la reserva.
    IF p_id_servicio IS NOT NULL THEN
      BEGIN
        BEGIN
          SELECT valor, id_alojamiento
          INTO   v_valor_servicio, v_aloj_servicio
          FROM   servicio
          WHERE  id_servicio = p_id_servicio;
        EXCEPTION
          WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_servicio,
              'El servicio ' || p_id_servicio || ' no existe.');
        END;

        IF v_aloj_servicio <> v_aloj_habitacion THEN
          RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_servicio,
            'El servicio ' || p_id_servicio || ' no pertenece al alojamiento de la reserva.');
        END IF;

        IF p_cantidad IS NULL OR p_cantidad < 1 THEN
          RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_servicio, 'La cantidad debe ser al menos 1.');
        END IF;

        INSERT INTO reserva_servicio (id_reserva_servicio, id_reserva, id_servicio,
                                      cantidad, valor_total)
        VALUES (seq_reserva_servicio.NEXTVAL, p_id_reserva, p_id_servicio,
                p_cantidad, v_valor_servicio * p_cantidad);

        UPDATE reserva
        SET    valor_total = valor_total + v_valor_servicio * p_cantidad
        WHERE  id_reserva  = p_id_reserva;

        DBMS_OUTPUT.PUT_LINE('2. Servicio ' || p_id_servicio || ' agregado a la reserva.');
      EXCEPTION
        WHEN OTHERS THEN
          v_codigo  := SQLCODE;
          v_mensaje := SQLERRM;
          ROLLBACK TO sp_reserva_registrada;
          sp_registrar_error('SERVICIO DE BIENVENIDA', p_id_cliente, p_id_habitacion,
                             v_entrada, v_salida, v_codigo, v_mensaje);
          DBMS_OUTPUT.PUT_LINE('2. El servicio no se agrego: ' || v_mensaje);
          DBMS_OUTPUT.PUT_LINE('   ROLLBACK TO sp_reserva_registrada: se deshizo solo el servicio, la reserva sigue.');
      END;
    END IF;

    -- 4. Pago por el valor total y confirmacion de toda la transaccion
    SELECT valor_total INTO v_total FROM reserva WHERE id_reserva = p_id_reserva;

    INSERT INTO pago (id_pago, id_reserva, fecha_pago, valor, metodo_pago)
    VALUES (seq_pago.NEXTVAL, p_id_reserva, SYSDATE, v_total, p_metodo_pago);

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('3. Pago de ' || v_total || ' con ' || p_metodo_pago
                         || ' registrado. COMMIT: reserva y pago quedan guardados.');

  EXCEPTION
    WHEN e_pago_invalido THEN
      v_codigo  := SQLCODE;
      v_mensaje := SQLERRM;
      ROLLBACK;
      sp_registrar_error('RESERVA Y PAGO', p_id_cliente, p_id_habitacion,
                         v_entrada, v_salida, v_codigo, v_mensaje);
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_dato_invalido,
        'El pago no se pudo registrar (metodo ' || p_metodo_pago || ' no permitido). '
        || 'ROLLBACK: no se guardo ni la reserva ni el pago.');
    WHEN OTHERS THEN
      v_codigo  := SQLCODE;
      v_mensaje := SQLERRM;
      ROLLBACK;
      sp_registrar_error('RESERVA Y PAGO', p_id_cliente, p_id_habitacion,
                         v_entrada, v_salida, v_codigo, v_mensaje);
      RAISE;
  END sp_reservar_y_pagar;

END pkg_transacciones;
/
SHOW ERRORS PACKAGE BODY pkg_transacciones


SET LINESIZE 140;
SET PAGESIZE 60;
SET FEEDBACK OFF;
SET TAB OFF;
ALTER SESSION SET NLS_DATE_FORMAT = 'DD/MM/YYYY';

PROMPT Estado del paquete:
COLUMN object_name FORMAT A18
COLUMN object_type FORMAT A14
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name = 'PKG_TRANSACCIONES'
ORDER  BY object_type;


-- =====================================================================
-- Demostracion
-- Habitacion 5 (suite para 4, alojamiento 5) en mayo de 2027. Primero se
-- borra lo que haya dejado una ejecucion anterior.
-- =====================================================================
DELETE FROM pago
WHERE  id_reserva IN (SELECT rh.id_reserva FROM reserva_habitacion rh JOIN reserva r ON r.id_reserva = rh.id_reserva
                      WHERE  rh.id_habitacion = 5 AND r.fecha_checkin BETWEEN DATE '2027-05-01' AND DATE '2027-05-31');
DELETE FROM reserva_servicio
WHERE  id_reserva IN (SELECT rh.id_reserva FROM reserva_habitacion rh JOIN reserva r ON r.id_reserva = rh.id_reserva
                      WHERE  rh.id_habitacion = 5 AND r.fecha_checkin BETWEEN DATE '2027-05-01' AND DATE '2027-05-31');
BEGIN
  FOR r IN (SELECT DISTINCT rh.id_reserva
            FROM   reserva_habitacion rh JOIN reserva re ON re.id_reserva = rh.id_reserva
            WHERE  rh.id_habitacion = 5
              AND  re.fecha_checkin BETWEEN DATE '2027-05-01' AND DATE '2027-05-31') LOOP
    DELETE FROM reserva_habitacion WHERE id_reserva = r.id_reserva;
    DELETE FROM reserva            WHERE id_reserva = r.id_reserva;
  END LOOP;
  COMMIT;
END;
/

COLUMN cliente     FORMAT A18
COLUMN servicios   FORMAT 999G999G999
COLUMN valor_total FORMAT 999G999G999
COLUMN pagado      FORMAT 999G999G999
COLUMN metodo      FORMAT A16

PROMPT
PROMPT Prueba T1: reserva, servicio de bienvenida y pago: todo sale bien y se confirma
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_transacciones.sp_reservar_y_pagar(
    p_id_cliente    => 10,
    p_id_habitacion => 5,
    p_fecha_in      => DATE '2027-05-10',
    p_fecha_out     => DATE '2027-05-13',
    p_num_huespedes => 2,
    p_metodo_pago   => 'TARJETA_CREDITO',
    p_id_servicio   => 63,
    p_cantidad      => 2,
    p_id_reserva    => v_id);
END;
/

PROMPT
PROMPT Prueba T2: rollback parcial. El servicio 2 es de otro alojamiento: se deshace
PROMPT            solo el servicio con ROLLBACK TO y la reserva y el pago si quedan
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_transacciones.sp_reservar_y_pagar(
    p_id_cliente    => 11,
    p_id_habitacion => 5,
    p_fecha_in      => DATE '2027-05-20',
    p_fecha_out     => DATE '2027-05-22',
    p_num_huespedes => 3,
    p_metodo_pago   => 'PSE',
    p_id_servicio   => 2,
    p_id_reserva    => v_id);
END;
/

PROMPT
PROMPT Prueba T3: rollback total. El metodo de pago BITCOIN no esta permitido: el pago falla
PROMPT            despues de registrar la reserva y se deshace todo
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_transacciones.sp_reservar_y_pagar(
    p_id_cliente    => 12,
    p_id_habitacion => 5,
    p_fecha_in      => DATE '2027-05-25',
    p_fecha_out     => DATE '2027-05-27',
    p_num_huespedes => 2,
    p_metodo_pago   => 'BITCOIN',
    p_id_reserva    => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba T4: la misma habitacion en fechas que se cruzan con la reserva de T1
DECLARE
  v_id reserva.id_reserva%TYPE;
BEGIN
  pkg_transacciones.sp_reservar_y_pagar(
    p_id_cliente    => 13,
    p_id_habitacion => 5,
    p_fecha_in      => DATE '2027-05-12',
    p_fecha_out     => DATE '2027-05-15',
    p_num_huespedes => 2,
    p_metodo_pago   => 'EFECTIVO',
    p_id_reserva    => v_id);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('   ' || SQLERRM);
END;
/

PROMPT
PROMPT Prueba T5: lo que quedo guardado en mayo de 2027 para la habitacion 5.
PROMPT            T1 con servicio, T2 sin servicio, y de T3 y T4 no queda nada
SELECT r.id_reserva, c.nombre AS cliente, r.fecha_checkin, r.fecha_checkout,
       (SELECT NVL(SUM(rs.valor_total), 0) FROM reserva_servicio rs
        WHERE  rs.id_reserva = r.id_reserva) AS servicios,
       r.valor_total,
       (SELECT NVL(SUM(p.valor), 0) FROM pago p WHERE p.id_reserva = r.id_reserva) AS pagado,
       (SELECT MAX(p.metodo_pago) FROM pago p WHERE p.id_reserva = r.id_reserva) AS metodo
FROM   reserva r
JOIN   cliente c ON c.id_cliente = r.id_cliente
WHERE  r.id_reserva IN (SELECT id_reserva FROM reserva_habitacion WHERE id_habitacion = 5)
  AND  r.fecha_checkin BETWEEN DATE '2027-05-01' AND DATE '2027-05-31'
ORDER  BY r.fecha_checkin;

PROMPT
PROMPT Prueba T6: la bitacora conserva los tres intentos fallidos aunque sus transacciones
PROMPT            se deshicieron (PRAGMA AUTONOMOUS_TRANSACTION)
COLUMN operacion FORMAT A22
COLUMN mensaje   FORMAT A70 WORD_WRAPPED
SELECT id_log, operacion, id_cliente, codigo_error, mensaje
FROM   log_errores_reserva
ORDER  BY id_log;

PROMPT
PROMPT Prueba T7: SAVEPOINT a mano. Se registra un pago, se marca un punto, se cambia su
PROMPT            valor y luego se deshace solo el cambio. Al final se deshace todo para no
PROMPT            alterar los datos.
DECLARE
  v_id_reserva  reserva.id_reserva%TYPE;
  v_id_pago     pago.id_pago%TYPE;
  v_valor       pago.valor%TYPE;
BEGIN
  SELECT MIN(r.id_reserva) INTO v_id_reserva
  FROM   reserva r JOIN reserva_habitacion rh ON rh.id_reserva = r.id_reserva
  WHERE  rh.id_habitacion = 5 AND r.fecha_checkin = DATE '2027-05-10';

  v_id_pago := seq_pago.NEXTVAL;
  INSERT INTO pago (id_pago, id_reserva, fecha_pago, valor, metodo_pago)
  VALUES (v_id_pago, v_id_reserva, SYSDATE, 50000, 'EFECTIVO');

  SAVEPOINT sp_pago_creado;

  UPDATE pago SET valor = 999999 WHERE id_pago = v_id_pago;
  SELECT valor INTO v_valor FROM pago WHERE id_pago = v_id_pago;
  DBMS_OUTPUT.PUT_LINE('Despues del UPDATE el pago vale        ' || v_valor);

  ROLLBACK TO sp_pago_creado;
  SELECT valor INTO v_valor FROM pago WHERE id_pago = v_id_pago;
  DBMS_OUTPUT.PUT_LINE('Despues de ROLLBACK TO el pago vale    ' || v_valor
                       || ' (el INSERT sigue, el UPDATE se deshizo)');

  ROLLBACK;
  SELECT COUNT(*) INTO v_valor FROM pago WHERE id_pago = v_id_pago;
  DBMS_OUTPUT.PUT_LINE('Despues de ROLLBACK quedan pagos con ese numero: ' || v_valor);
END;
/
