-- TurismoUQ - Script 13: pruebas de seguridad (Entrega 3)
-- Se conecta como cada usuario y muestra lo que puede hacer y lo que Oracle
-- le niega. Ninguna prueba modifica datos: las operaciones permitidas se
-- prueban con valores que el paquete rechaza despues de pasar el control de
-- permisos, para mostrar hasta donde llega cada usuario.
-- Ejecutar despues del script 12, desde cualquier usuario (el script hace
-- CONNECT con cada uno).
--
-- Datos usados: la reserva 35 y la tarifa 8001 son del alojamiento 1; la
-- reserva 5, la tarifa 8085 y la habitacion 13 son del alojamiento 13.
--
-- Errores que se esperan:
--   ORA-00942  la tabla o vista no existe: el usuario no tiene ningun permiso
--              sobre ella, Oracle ni siquiera le deja saber que existe.
--   ORA-01031  privilegios insuficientes: puede ver la tabla pero no
--              modificarla.
--   PLS-00201  el identificador debe declararse: no tiene EXECUTE sobre ese
--              paquete.
--   ORA-20013  el paquete de su rol no lo deja operar sobre otra sede.

SET DEFINE OFF;
SET SERVEROUTPUT ON;
SET LINESIZE 140;
SET PAGESIZE 50;
SET FEEDBACK OFF;

-- =====================================================================
PROMPT
PROMPT =================================================================
PROMPT RECEPCION - usuario recep001 (alojamiento 1)
PROMPT =================================================================
CONNECT recep001/"Recepcion.2026"@localhost:1521/XEPDB1
SET SERVEROUTPUT ON;

PROMPT S1. Sus vistas: solo ve lo de su sede
SELECT (SELECT COUNT(*) FROM turismouq.v_sede_reservas)     AS reservas_de_su_sede,
       (SELECT COUNT(*) FROM turismouq.v_sede_habitaciones) AS habitaciones,
       (SELECT COUNT(*) FROM turismouq.v_sede_servicios)    AS servicios,
       (SELECT COUNT(*) FROM turismouq.v_clientes)          AS clientes
FROM   dual;

PROMPT S2. Leer la tabla RESERVA directamente (debe fallar con ORA-00942)
SELECT COUNT(*) FROM turismouq.reserva;

PROMPT S3. Modificar la tabla RESERVA directamente (debe fallar con ORA-00942)
UPDATE turismouq.reserva SET estado = 'CANCELADA' WHERE id_reserva = 35;

PROMPT S4. Check-out de la reserva 5, que es del alojamiento 13 (debe fallar con ORA-20013)
BEGIN
  turismouq.pkg_recepcion.sp_checkout(p_id_reserva => 5);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE(SQLERRM);
END;
/

PROMPT S5. Check-out de la reserva 35, que si es de su sede: pasa el control de sede
PROMPT     y la rechaza la regla del negocio porque ya esta FINALIZADA (ORA-20008)
BEGIN
  turismouq.pkg_recepcion.sp_checkout(p_id_reserva => 35);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE(SQLERRM);
END;
/

PROMPT S6. Usar el paquete principal o el del administrador (debe fallar con PLS-00201)
BEGIN
  turismouq.pkg_turismouq.sp_cancelar_reserva(p_id_reserva => 35);
END;
/
BEGIN
  turismouq.pkg_administracion.sp_cambiar_estado_habitacion(1, 'MANTENIMIENTO');
END;
/

PROMPT S7. Los limites de su perfil
COLUMN resource_name FORMAT A24
COLUMN limit         FORMAT A12
SELECT resource_name, limit
FROM   user_resource_limits
WHERE  resource_name IN ('SESSIONS_PER_USER', 'IDLE_TIME', 'CONNECT_TIME');


-- =====================================================================
PROMPT
PROMPT =================================================================
PROMPT RECEPCION - usuario recep013 (alojamiento 13): las mismas vistas, otros datos
PROMPT =================================================================
CONNECT recep013/"Recepcion.2026"@localhost:1521/XEPDB1
SET SERVEROUTPUT ON;
SELECT (SELECT COUNT(*) FROM turismouq.v_sede_reservas)     AS reservas_de_su_sede,
       (SELECT COUNT(*) FROM turismouq.v_sede_habitaciones) AS habitaciones,
       (SELECT MIN(numero) || ' a ' || MAX(numero) FROM turismouq.v_sede_habitaciones) AS numeros
FROM   dual;


-- =====================================================================
PROMPT
PROMPT =================================================================
PROMPT ADMINISTRADOR DE ALOJAMIENTO - usuario admin001 (alojamiento 1)
PROMPT =================================================================
CONNECT admin001/"Admin.2026"@localhost:1521/XEPDB1
SET SERVEROUTPUT ON;

PROMPT A1. Sus vistas: tarifas y habitaciones de su sede
SELECT (SELECT COUNT(*) FROM turismouq.v_sede_tarifas)                       AS tarifas,
       (SELECT COUNT(*) FROM turismouq.v_sede_tarifas WHERE editable = 'SI') AS tarifas_editables,
       (SELECT COUNT(*) FROM turismouq.v_sede_habitaciones)                  AS habitaciones
FROM   dual;

PROMPT A2. Ver las reservas de recepcion (debe fallar con ORA-00942)
SELECT COUNT(*) FROM turismouq.v_sede_reservas;

PROMPT A3. Cambiar la tarifa 8085, del alojamiento 13 (debe fallar con ORA-20013)
BEGIN
  turismouq.pkg_administracion.sp_actualizar_tarifa(p_id_tarifa => 8085, p_valor_noche => 300000);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE(SQLERRM);
END;
/

PROMPT A4. Poner en cero la tarifa 8001, de su sede: pasa el control de sede y la
PROMPT     rechaza la regla del negocio (ORA-20011)
BEGIN
  turismouq.pkg_administracion.sp_actualizar_tarifa(p_id_tarifa => 8001, p_valor_noche => 0);
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE(SQLERRM);
END;
/

PROMPT A5. Cambiar el estado de la habitacion 13, del alojamiento 13 (debe fallar con ORA-20013)
BEGIN
  turismouq.pkg_administracion.sp_cambiar_estado_habitacion(p_id_habitacion => 13,
                                                            p_estado => 'DISPONIBLE');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE(SQLERRM);
END;
/

PROMPT A6. Modificar la tabla TARIFA directamente (debe fallar con ORA-00942)
UPDATE turismouq.tarifa SET valor_noche = 1 WHERE id_tarifa = 8001;


-- =====================================================================
PROMPT
PROMPT =================================================================
PROMPT GERENTE - usuario gerente1
PROMPT =================================================================
CONNECT gerente1/"Gerente.2026"@localhost:1521/XEPDB1
SET SERVEROUTPUT ON;

PROMPT G1. Lee todas las tablas del negocio
SELECT (SELECT COUNT(*) FROM turismouq.reserva)     AS reservas,
       (SELECT COUNT(*) FROM turismouq.alojamiento) AS alojamientos,
       (SELECT COUNT(*) FROM turismouq.pago)        AS pagos
FROM   dual;

PROMPT G2. Borrar reservas (debe fallar con ORA-01031: las ve pero no las puede modificar)
DELETE FROM turismouq.reserva WHERE id_reserva = 35;

PROMPT G3. Usa el paquete de gerencia: reporte de un mes que no esta liquidado (ORA-20007)
BEGIN
  turismouq.pkg_gerencia.sp_reporte_liquidacion(p_periodo => DATE '2020-01-01');
EXCEPTION
  WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE(SQLERRM);
END;
/

PROMPT G4. Ver la bitacora de auditoria (debe fallar con ORA-00942: es del auditor)
SELECT COUNT(*) FROM turismouq.auditoria_tarifa;


-- =====================================================================
PROMPT
PROMPT =================================================================
PROMPT AUDITOR - usuario auditor1
PROMPT =================================================================
CONNECT auditor1/"Auditor.2026"@localhost:1521/XEPDB1
SET SERVEROUTPUT ON;

PROMPT U1. Lee lo que audita
SELECT (SELECT COUNT(*) FROM turismouq.auditoria_tarifa)    AS cambios_de_tarifa,
       (SELECT COUNT(*) FROM turismouq.log_errores_reserva) AS intentos_fallidos,
       (SELECT COUNT(*) FROM turismouq.pago)                AS pagos
FROM   dual;

PROMPT U2. Borrar un registro de la auditoria (debe fallar con ORA-01031)
DELETE FROM turismouq.auditoria_tarifa;

PROMPT U3. Liquidar un mes (debe fallar con PLS-00201: no tiene ningun paquete)
BEGIN
  turismouq.pkg_gerencia.sp_liquidar_mes(p_periodo => DATE '2025-06-01');
END;
/

PROMPT U4. Ver los datos de los clientes (debe fallar con ORA-00942)
SELECT COUNT(*) FROM turismouq.cliente;


-- =====================================================================
PROMPT
PROMPT =================================================================
PROMPT PORTAL DEL HUESPED - usuario portal_web (la aplicacion web)
PROMPT =================================================================
CONNECT portal_web/"PortalWeb.2026"@localhost:1521/XEPDB1
SET SERVEROUTPUT ON;

PROMPT W1. Ve el catalogo publico
SELECT (SELECT COUNT(*) FROM turismouq.v_catalogo_alojamientos) AS alojamientos,
       (SELECT COUNT(*) FROM turismouq.v_catalogo_habitaciones) AS habitaciones,
       (SELECT COUNT(*) FROM turismouq.v_catalogo_servicios)    AS servicios
FROM   dual;

PROMPT W2. Buscar a un cliente por su documento: solo recibe su numero y su nombre
DECLARE
  v_id     NUMBER;
  v_nombre VARCHAR2(100);
BEGIN
  turismouq.pkg_portal.sp_buscar_cliente(p_documento => '1000007',
                                         p_id_cliente => v_id, p_nombre => v_nombre);
  DBMS_OUTPUT.PUT_LINE('Cliente ' || v_id || ': ' || v_nombre);
END;
/

PROMPT W3. Listar los clientes o las reservas (debe fallar con ORA-00942)
SELECT COUNT(*) FROM turismouq.cliente;
SELECT COUNT(*) FROM turismouq.v_clientes;

SET FEEDBACK ON;

-- =====================================================================
-- LIMITE DE SESIONES DEL PERFIL (se demuestra a mano)
-- El perfil PERFIL_TURISMOUQ permite 2 sesiones abiertas al tiempo por
-- usuario. Para verlo, abrir tres ventanas de SQL*Plus y en cada una:
--   sqlplus recep001/"Recepcion.2026"@localhost:1521/XEPDB1
-- Las dos primeras se conectan. La tercera recibe:
--   ORA-02391: ha excedido el limite de SESSIONS_PER_USER simultaneas
-- =====================================================================
PROMPT
PROMPT Para el limite de sesiones: abra tres ventanas con recep001; la tercera
PROMPT recibe ORA-02391 (ver el comentario al final de este script).
