-- TurismoUQ - Script 11: vistas y paquetes por rol (Entrega 3, seguridad)
-- Lo que cada rol va a poder usar: las vistas de su sede y un paquete con
-- solo las operaciones de su cargo. Los permisos se dan en el script 12.
-- Ejecutar como TURISMOUQ despues del script 10.
--
-- Como sabe Oracle de que sede es cada usuario: la tabla USUARIO_SISTEMA (del
-- modelo de la Entrega 1) dice que recep001 y admin001 son del alojamiento 1,
-- recep013 del 13, etc. Los usuarios de Oracle se llaman igual, asi que las
-- vistas comparan USUARIO_SISTEMA.USERNAME con el usuario que inicio sesion
-- (SYS_CONTEXT('USERENV', 'SESSION_USER')) y muestran solo lo de su sede.

SET DEFINE OFF;

-- Alojamiento del usuario que inicio sesion (NULL si no tiene sede, por
-- ejemplo el gerente, el auditor o TURISMOUQ)
CREATE OR REPLACE FUNCTION fn_sede_usuario
RETURN alojamiento.id_alojamiento%TYPE
IS
  v_sede alojamiento.id_alojamiento%TYPE;
BEGIN
  SELECT id_alojamiento
  INTO   v_sede
  FROM   usuario_sistema
  WHERE  UPPER(username) = SYS_CONTEXT('USERENV', 'SESSION_USER');
  RETURN v_sede;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RETURN NULL;
END fn_sede_usuario;
/
SHOW ERRORS FUNCTION fn_sede_usuario


-- =====================================================================
-- VISTAS
-- =====================================================================

-- Reservas de la sede, con lo pagado y el saldo
CREATE OR REPLACE VIEW v_sede_reservas AS
SELECT r.id_reserva,
       c.nombre                                         AS cliente,
       c.documento,
       LISTAGG(DISTINCT h.numero, ', ') WITHIN GROUP (ORDER BY h.numero) AS habitaciones,
       r.fecha_checkin,
       r.fecha_checkout,
       r.num_huespedes,
       r.estado,
       r.valor_total,
       NVL((SELECT SUM(p.valor) FROM pago p WHERE p.id_reserva = r.id_reserva), 0) AS pagado,
       r.valor_total
         - NVL((SELECT SUM(p.valor) FROM pago p WHERE p.id_reserva = r.id_reserva), 0) AS saldo
FROM   reserva r
JOIN   cliente c             ON c.id_cliente    = r.id_cliente
JOIN   reserva_habitacion rh ON rh.id_reserva   = r.id_reserva
JOIN   habitacion h          ON h.id_habitacion = rh.id_habitacion
WHERE  h.id_alojamiento = (SELECT us.id_alojamiento FROM usuario_sistema us
                           WHERE  UPPER(us.username) = SYS_CONTEXT('USERENV', 'SESSION_USER'))
GROUP  BY r.id_reserva, c.nombre, c.documento, r.fecha_checkin, r.fecha_checkout,
          r.num_huespedes, r.estado, r.valor_total;

-- Habitaciones de la sede y si estan ocupadas hoy
CREATE OR REPLACE VIEW v_sede_habitaciones AS
SELECT h.id_habitacion,
       h.numero,
       h.tipo_habitacion,
       h.capacidad,
       h.estado,
       CASE WHEN EXISTS (SELECT 1
                         FROM   reserva_habitacion rh
                         JOIN   reserva r ON r.id_reserva = rh.id_reserva
                         WHERE  rh.id_habitacion = h.id_habitacion
                           AND  r.estado = 'CONFIRMADA'
                           AND  r.fecha_checkin  <= TRUNC(SYSDATE)
                           AND  r.fecha_checkout >  TRUNC(SYSDATE))
            THEN 'SI' ELSE 'NO' END AS ocupada_hoy
FROM   habitacion h
WHERE  h.id_alojamiento = (SELECT us.id_alojamiento FROM usuario_sistema us
                           WHERE  UPPER(us.username) = SYS_CONTEXT('USERENV', 'SESSION_USER'));

-- Servicios de la sede
CREATE OR REPLACE VIEW v_sede_servicios AS
SELECT s.id_servicio, s.nombre, s.valor
FROM   servicio s
WHERE  s.id_alojamiento = (SELECT us.id_alojamiento FROM usuario_sistema us
                           WHERE  UPPER(us.username) = SYS_CONTEXT('USERENV', 'SESSION_USER'));

-- Tarifas de las habitaciones de la sede, y si todavia se pueden cambiar
CREATE OR REPLACE VIEW v_sede_tarifas AS
SELECT tf.id_tarifa,
       h.numero        AS habitacion,
       t.nombre        AS temporada,
       t.tipo,
       t.fecha_inicio,
       t.fecha_fin,
       tf.valor_noche,
       CASE WHEN t.fecha_inicio > TRUNC(SYSDATE) THEN 'SI' ELSE 'NO' END AS editable
FROM   tarifa tf
JOIN   habitacion h ON h.id_habitacion = tf.id_habitacion
JOIN   temporada t  ON t.id_temporada  = tf.id_temporada
WHERE  h.id_alojamiento = (SELECT us.id_alojamiento FROM usuario_sistema us
                           WHERE  UPPER(us.username) = SYS_CONTEXT('USERENV', 'SESSION_USER'));

-- Datos de contacto de los clientes, sin nada mas, para buscar al huesped
CREATE OR REPLACE VIEW v_clientes AS
SELECT id_cliente, nombre, documento, email
FROM   cliente;


-- =====================================================================
-- PAQUETES POR ROL
-- Oracle da el permiso EXECUTE sobre un paquete completo, no sobre un solo
-- procedimiento. Si se le diera a recepcion EXECUTE sobre PKG_TURISMOUQ
-- tambien podria cambiar tarifas o liquidar meses. Por eso cada rol tiene su
-- propio paquete, que solo expone sus operaciones, revisa que sean de su sede
-- y llama a PKG_TURISMOUQ, donde estan todas las reglas.
-- Los paquetes se ejecutan con los permisos de TURISMOUQ (su dueno): el
-- usuario puede hacer la operacion sin tener ningun permiso sobre las tablas.
-- =====================================================================

CREATE OR REPLACE PACKAGE pkg_recepcion IS
  PROCEDURE sp_registrar_cliente (
    p_nombre      IN  cliente.nombre%TYPE,
    p_documento   IN  cliente.documento%TYPE,
    p_email       IN  cliente.email%TYPE,
    p_id_cliente  OUT cliente.id_cliente%TYPE
  );

  PROCEDURE sp_crear_reserva (
    p_id_cliente     IN  cliente.id_cliente%TYPE,
    p_id_habitacion  IN  habitacion.id_habitacion%TYPE,
    p_fecha_in       IN  reserva.fecha_checkin%TYPE,
    p_fecha_out      IN  reserva.fecha_checkout%TYPE,
    p_num_huespedes  IN  reserva.num_huespedes%TYPE,
    p_id_reserva     OUT reserva.id_reserva%TYPE
  );

  PROCEDURE sp_agregar_servicio (
    p_id_reserva   IN reserva.id_reserva%TYPE,
    p_id_servicio  IN servicio.id_servicio%TYPE,
    p_cantidad     IN reserva_servicio.cantidad%TYPE
  );

  PROCEDURE sp_checkout (
    p_id_reserva   IN reserva.id_reserva%TYPE,
    p_metodo_pago  IN pago.metodo_pago%TYPE DEFAULT 'TARJETA_CREDITO'
  );

  PROCEDURE sp_cancelar_reserva (
    p_id_reserva   IN reserva.id_reserva%TYPE
  );
END pkg_recepcion;
/
SHOW ERRORS PACKAGE pkg_recepcion

CREATE OR REPLACE PACKAGE BODY pkg_recepcion IS

  -- Sede del usuario; si no tiene, no puede operar en recepcion
  FUNCTION fn_sede RETURN NUMBER IS
    v_sede NUMBER := fn_sede_usuario;
  BEGIN
    IF v_sede IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_otra_sede,
        'El usuario ' || SYS_CONTEXT('USERENV', 'SESSION_USER')
        || ' no tiene un alojamiento asignado en USUARIO_SISTEMA.');
    END IF;
    RETURN v_sede;
  END fn_sede;

  -- La reserva tiene que ser de una habitacion de la sede del usuario. Si la
  -- reserva no existe se deja pasar: el procedimiento de PKG_TURISMOUQ da el
  -- error de reserva inexistente.
  PROCEDURE pr_validar_reserva (p_id_reserva IN reserva.id_reserva%TYPE) IS
    v_sede    NUMBER := fn_sede;
    v_de_sede NUMBER;
    v_existe  NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_existe FROM reserva WHERE id_reserva = p_id_reserva;

    SELECT COUNT(*)
    INTO   v_de_sede
    FROM   reserva_habitacion rh
    JOIN   habitacion h ON h.id_habitacion = rh.id_habitacion
    WHERE  rh.id_reserva     = p_id_reserva
      AND  h.id_alojamiento  = v_sede;

    IF v_existe > 0 AND v_de_sede = 0 THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_otra_sede,
        'La reserva ' || p_id_reserva || ' no es del alojamiento ' || v_sede
        || ', que es el del usuario ' || SYS_CONTEXT('USERENV', 'SESSION_USER') || '.');
    END IF;
  END pr_validar_reserva;

  PROCEDURE sp_registrar_cliente (
    p_nombre      IN  cliente.nombre%TYPE,
    p_documento   IN  cliente.documento%TYPE,
    p_email       IN  cliente.email%TYPE,
    p_id_cliente  OUT cliente.id_cliente%TYPE
  ) IS
  BEGIN
    pkg_turismouq.sp_registrar_cliente(p_nombre, p_documento, p_email, p_id_cliente);
  END sp_registrar_cliente;

  PROCEDURE sp_crear_reserva (
    p_id_cliente     IN  cliente.id_cliente%TYPE,
    p_id_habitacion  IN  habitacion.id_habitacion%TYPE,
    p_fecha_in       IN  reserva.fecha_checkin%TYPE,
    p_fecha_out      IN  reserva.fecha_checkout%TYPE,
    p_num_huespedes  IN  reserva.num_huespedes%TYPE,
    p_id_reserva     OUT reserva.id_reserva%TYPE
  ) IS
    v_sede  NUMBER := fn_sede;
    v_aloj  habitacion.id_alojamiento%TYPE;
  BEGIN
    SELECT MAX(id_alojamiento) INTO v_aloj FROM habitacion WHERE id_habitacion = p_id_habitacion;
    IF v_aloj IS NOT NULL AND v_aloj <> v_sede THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_otra_sede,
        'La habitacion ' || p_id_habitacion || ' no es del alojamiento ' || v_sede || '.');
    END IF;
    pkg_turismouq.sp_crear_reserva(p_id_cliente, p_id_habitacion, p_fecha_in, p_fecha_out,
                                   p_num_huespedes, p_id_reserva);
  END sp_crear_reserva;

  PROCEDURE sp_agregar_servicio (
    p_id_reserva   IN reserva.id_reserva%TYPE,
    p_id_servicio  IN servicio.id_servicio%TYPE,
    p_cantidad     IN reserva_servicio.cantidad%TYPE
  ) IS
  BEGIN
    pr_validar_reserva(p_id_reserva);
    pkg_turismouq.sp_agregar_servicio(p_id_reserva, p_id_servicio, p_cantidad);
  END sp_agregar_servicio;

  PROCEDURE sp_checkout (
    p_id_reserva   IN reserva.id_reserva%TYPE,
    p_metodo_pago  IN pago.metodo_pago%TYPE DEFAULT 'TARJETA_CREDITO'
  ) IS
  BEGIN
    pr_validar_reserva(p_id_reserva);
    pkg_turismouq.sp_checkout(p_id_reserva, p_metodo_pago);
  END sp_checkout;

  PROCEDURE sp_cancelar_reserva (
    p_id_reserva   IN reserva.id_reserva%TYPE
  ) IS
  BEGIN
    pr_validar_reserva(p_id_reserva);
    pkg_turismouq.sp_cancelar_reserva(p_id_reserva);
  END sp_cancelar_reserva;

END pkg_recepcion;
/
SHOW ERRORS PACKAGE BODY pkg_recepcion


CREATE OR REPLACE PACKAGE pkg_administracion IS
  PROCEDURE sp_actualizar_tarifa (
    p_id_tarifa    IN tarifa.id_tarifa%TYPE,
    p_valor_noche  IN tarifa.valor_noche%TYPE
  );

  PROCEDURE sp_ajustar_tarifas (
    p_anio        IN  NUMBER,
    p_porcentaje  IN  NUMBER,
    p_afectadas   OUT NUMBER
  );

  PROCEDURE sp_cambiar_estado_habitacion (
    p_id_habitacion  IN habitacion.id_habitacion%TYPE,
    p_estado         IN habitacion.estado%TYPE
  );
END pkg_administracion;
/
SHOW ERRORS PACKAGE pkg_administracion

CREATE OR REPLACE PACKAGE BODY pkg_administracion IS

  FUNCTION fn_sede RETURN NUMBER IS
    v_sede NUMBER := fn_sede_usuario;
  BEGIN
    IF v_sede IS NULL THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_otra_sede,
        'El usuario ' || SYS_CONTEXT('USERENV', 'SESSION_USER')
        || ' no tiene un alojamiento asignado en USUARIO_SISTEMA.');
    END IF;
    RETURN v_sede;
  END fn_sede;

  -- La habitacion tiene que ser de la sede del usuario
  PROCEDURE pr_validar_habitacion (p_id_habitacion IN habitacion.id_habitacion%TYPE) IS
    v_sede  NUMBER := fn_sede;
    v_aloj  habitacion.id_alojamiento%TYPE;
  BEGIN
    SELECT MAX(id_alojamiento) INTO v_aloj FROM habitacion WHERE id_habitacion = p_id_habitacion;
    IF v_aloj IS NOT NULL AND v_aloj <> v_sede THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_otra_sede,
        'La habitacion ' || p_id_habitacion || ' no es del alojamiento ' || v_sede
        || ', que es el del usuario ' || SYS_CONTEXT('USERENV', 'SESSION_USER') || '.');
    END IF;
  END pr_validar_habitacion;

  PROCEDURE sp_actualizar_tarifa (
    p_id_tarifa    IN tarifa.id_tarifa%TYPE,
    p_valor_noche  IN tarifa.valor_noche%TYPE
  ) IS
    v_habitacion tarifa.id_habitacion%TYPE;
  BEGIN
    SELECT MAX(id_habitacion) INTO v_habitacion FROM tarifa WHERE id_tarifa = p_id_tarifa;
    pr_validar_habitacion(v_habitacion);
    pkg_turismouq.sp_actualizar_tarifa(p_id_tarifa, p_valor_noche);
  END sp_actualizar_tarifa;

  -- Siempre sobre el alojamiento del usuario: no recibe el alojamiento
  PROCEDURE sp_ajustar_tarifas (
    p_anio        IN  NUMBER,
    p_porcentaje  IN  NUMBER,
    p_afectadas   OUT NUMBER
  ) IS
  BEGIN
    pkg_turismouq.sp_ajustar_tarifas(fn_sede, p_anio, p_porcentaje, p_afectadas);
  END sp_ajustar_tarifas;

  PROCEDURE sp_cambiar_estado_habitacion (
    p_id_habitacion  IN habitacion.id_habitacion%TYPE,
    p_estado         IN habitacion.estado%TYPE
  ) IS
  BEGIN
    pr_validar_habitacion(p_id_habitacion);
    pkg_turismouq.sp_cambiar_estado_habitacion(p_id_habitacion, p_estado);
  END sp_cambiar_estado_habitacion;

END pkg_administracion;
/
SHOW ERRORS PACKAGE BODY pkg_administracion


-- El gerente trabaja sobre todos los alojamientos: no se filtra por sede
CREATE OR REPLACE PACKAGE pkg_gerencia IS
  PROCEDURE sp_liquidar_mes (
    p_periodo     IN DATE,
    p_porcentaje  IN NUMBER DEFAULT 12
  );

  PROCEDURE sp_reabrir_liquidacion (
    p_periodo  IN DATE
  );

  PROCEDURE sp_reporte_liquidacion (
    p_periodo         IN DATE,
    p_id_alojamiento  IN alojamiento.id_alojamiento%TYPE DEFAULT NULL
  );
END pkg_gerencia;
/
SHOW ERRORS PACKAGE pkg_gerencia

CREATE OR REPLACE PACKAGE BODY pkg_gerencia IS

  PROCEDURE sp_liquidar_mes (
    p_periodo     IN DATE,
    p_porcentaje  IN NUMBER DEFAULT 12
  ) IS
  BEGIN
    pkg_turismouq.sp_liquidar_mes(p_periodo, p_porcentaje);
  END sp_liquidar_mes;

  PROCEDURE sp_reabrir_liquidacion (
    p_periodo  IN DATE
  ) IS
  BEGIN
    pkg_turismouq.sp_reabrir_liquidacion(p_periodo);
  END sp_reabrir_liquidacion;

  PROCEDURE sp_reporte_liquidacion (
    p_periodo         IN DATE,
    p_id_alojamiento  IN alojamiento.id_alojamiento%TYPE DEFAULT NULL
  ) IS
  BEGIN
    pkg_turismouq.sp_reporte_liquidacion(p_periodo, p_id_alojamiento);
  END sp_reporte_liquidacion;

END pkg_gerencia;
/
SHOW ERRORS PACKAGE BODY pkg_gerencia


SET LINESIZE 120;
SET PAGESIZE 50;
COLUMN object_name FORMAT A22
COLUMN object_type FORMAT A14
PROMPT Objetos creados para la seguridad:
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('FN_SEDE_USUARIO', 'V_SEDE_RESERVAS', 'V_SEDE_HABITACIONES',
                       'V_SEDE_SERVICIOS', 'V_SEDE_TARIFAS', 'V_CLIENTES',
                       'PKG_RECEPCION', 'PKG_ADMINISTRACION', 'PKG_GERENCIA')
ORDER  BY object_type, object_name;
