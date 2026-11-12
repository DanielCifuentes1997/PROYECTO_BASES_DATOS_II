-- TurismoUQ - Script 12: perfil, roles y usuarios (Entrega 3, seguridad)
-- Ejecutar como SYS en la PDB XEPDB1 despues del script 11:
--   sqlplus sys/<clave>@localhost:1521/XEPDB1 as sysdba
--
-- Cuatro roles con privilegios distintos:
--   ROL_RECEPCION          solo vistas de su sede y el paquete de recepcion.
--                          Ningun permiso sobre tablas.
--   ROL_ADMIN_ALOJAMIENTO  vistas de habitaciones, tarifas y servicios de su
--                          sede, catalogos de solo lectura y el paquete de
--                          administracion.
--   ROL_GERENTE            lectura de todas las tablas del negocio para sus
--                          analisis y el paquete de gerencia (liquidacion).
--   ROL_AUDITOR            solo lectura de lo que se audita: cambios de
--                          tarifas, intentos fallidos, pagos y liquidaciones.
-- Y un quinto rol para la aplicacion web:
--   ROL_PORTAL_WEB         el portal publico del huesped: solo el catalogo
--                          (vistas) y el paquete del portal. No ve clientes,
--                          reservas ni pagos.
-- Los usuarios se llaman como en USUARIO_SISTEMA para que las vistas sepan su
-- sede: recep001 y admin001 (alojamiento 1), recep013 (alojamiento 13),
-- gerente1 y auditor1.

SET DEFINE OFF;
SET SERVEROUTPUT ON;

-- Borra lo que crea el script, para poder ejecutarlo de nuevo
DECLARE
  PROCEDURE borrar(p_sentencia VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sentencia;
  EXCEPTION
    WHEN OTHERS THEN NULL;   -- no existia
  END;
BEGIN
  FOR u IN (SELECT username FROM dba_users
            WHERE  username IN ('RECEP001', 'RECEP013', 'ADMIN001', 'GERENTE1', 'AUDITOR1',
                                'PORTAL_WEB')) LOOP
    EXECUTE IMMEDIATE 'DROP USER ' || u.username || ' CASCADE';
  END LOOP;
  borrar('DROP ROLE rol_recepcion');
  borrar('DROP ROLE rol_admin_alojamiento');
  borrar('DROP ROLE rol_gerente');
  borrar('DROP ROLE rol_auditor');
  borrar('DROP ROLE rol_portal_web');
  borrar('DROP PROFILE perfil_turismouq CASCADE');
  borrar('DROP PROFILE perfil_portal CASCADE');
END;
/


-- =====================================================================
-- PERFIL CON LIMITES DE SESION
-- =====================================================================
-- SESSIONS_PER_USER      2 sesiones abiertas al tiempo por usuario: una
--                        recepcionista no necesita mas; evita que una
--                        cuenta compartida se use desde muchos equipos.
-- IDLE_TIME              15 minutos sin hacer nada y Oracle cierra la sesion
--                        (y libera los bloqueos que tuviera).
-- CONNECT_TIME           8 horas como maximo por sesion, un turno.
-- FAILED_LOGIN_ATTEMPTS  3 claves erradas seguidas bloquean la cuenta...
-- PASSWORD_LOCK_TIME     ...durante 15 minutos (1/96 de dia).
-- PASSWORD_LIFE_TIME     la clave vence a los 90 dias.
-- Los limites de recursos solo se aplican si el parametro RESOURCE_LIMIT
-- esta en TRUE, que es su valor por defecto desde Oracle 12c.
CREATE PROFILE perfil_turismouq LIMIT
  SESSIONS_PER_USER      2
  IDLE_TIME              15
  CONNECT_TIME           480
  FAILED_LOGIN_ATTEMPTS  3
  PASSWORD_LOCK_TIME     1/96
  PASSWORD_LIFE_TIME     90;

-- Perfil de la cuenta de la aplicacion web (PORTAL_WEB). El servidor mantiene
-- abiertas hasta 4 conexiones para atender a varios huespedes a la vez y no
-- debe cerrarse por inactividad; la clave no vence para que el portal no se
-- caiga, pero sigue bloqueandose con 5 intentos fallidos.
CREATE PROFILE perfil_portal LIMIT
  SESSIONS_PER_USER      4
  IDLE_TIME              UNLIMITED
  FAILED_LOGIN_ATTEMPTS  5
  PASSWORD_LOCK_TIME     1/96
  PASSWORD_LIFE_TIME     UNLIMITED;


-- =====================================================================
-- ROLES Y SUS PRIVILEGIOS
-- =====================================================================
CREATE ROLE rol_recepcion;
CREATE ROLE rol_admin_alojamiento;
CREATE ROLE rol_gerente;
CREATE ROLE rol_auditor;
CREATE ROLE rol_portal_web;

-- Recepcion: solo vistas, nunca tablas. Lo que modifica lo hace con el
-- paquete de recepcion, que corre con los permisos de TURISMOUQ.
GRANT SELECT ON turismouq.v_sede_reservas     TO rol_recepcion;
GRANT SELECT ON turismouq.v_sede_habitaciones TO rol_recepcion;
GRANT SELECT ON turismouq.v_sede_servicios    TO rol_recepcion;
GRANT SELECT ON turismouq.v_clientes          TO rol_recepcion;
GRANT SELECT ON turismouq.v_sede_estadias     TO rol_recepcion;
GRANT SELECT ON turismouq.v_sede_consumos     TO rol_recepcion;
GRANT SELECT ON turismouq.v_mi_sede           TO rol_recepcion;
GRANT EXECUTE ON turismouq.pkg_recepcion      TO rol_recepcion;

-- Administrador de alojamiento: lo de su sede y los catalogos generales
GRANT SELECT ON turismouq.v_sede_habitaciones TO rol_admin_alojamiento;
GRANT SELECT ON turismouq.v_sede_tarifas      TO rol_admin_alojamiento;
GRANT SELECT ON turismouq.v_sede_servicios    TO rol_admin_alojamiento;
GRANT SELECT ON turismouq.v_mi_sede           TO rol_admin_alojamiento;
GRANT SELECT ON turismouq.temporada           TO rol_admin_alojamiento;
GRANT SELECT ON turismouq.tipo_alojamiento    TO rol_admin_alojamiento;
GRANT EXECUTE ON turismouq.pkg_administracion TO rol_admin_alojamiento;

-- Gerente: lee todo el negocio y liquida; no modifica ninguna tabla directo
GRANT SELECT ON turismouq.municipio            TO rol_gerente;
GRANT SELECT ON turismouq.tipo_alojamiento     TO rol_gerente;
GRANT SELECT ON turismouq.alojamiento          TO rol_gerente;
GRANT SELECT ON turismouq.habitacion           TO rol_gerente;
GRANT SELECT ON turismouq.temporada            TO rol_gerente;
GRANT SELECT ON turismouq.tarifa               TO rol_gerente;
GRANT SELECT ON turismouq.cliente              TO rol_gerente;
GRANT SELECT ON turismouq.reserva              TO rol_gerente;
GRANT SELECT ON turismouq.reserva_habitacion   TO rol_gerente;
GRANT SELECT ON turismouq.servicio             TO rol_gerente;
GRANT SELECT ON turismouq.reserva_servicio     TO rol_gerente;
GRANT SELECT ON turismouq.pago                 TO rol_gerente;
GRANT SELECT ON turismouq.resena               TO rol_gerente;
GRANT SELECT ON turismouq.liquidacion_mensual  TO rol_gerente;
GRANT SELECT ON turismouq.liquidacion_detalle  TO rol_gerente;
GRANT SELECT ON turismouq.mv_ocupacion_mensual TO rol_gerente;
GRANT EXECUTE ON turismouq.pkg_gerencia        TO rol_gerente;

-- Auditor: solo lectura de lo que se revisa; ni ejecuta ni modifica nada
GRANT SELECT ON turismouq.auditoria_tarifa     TO rol_auditor;
GRANT SELECT ON turismouq.log_errores_reserva  TO rol_auditor;
GRANT SELECT ON turismouq.pago                 TO rol_auditor;
GRANT SELECT ON turismouq.reserva              TO rol_auditor;
GRANT SELECT ON turismouq.liquidacion_mensual  TO rol_auditor;
GRANT SELECT ON turismouq.liquidacion_detalle  TO rol_auditor;
GRANT SELECT ON turismouq.usuario_sistema      TO rol_auditor;
GRANT SELECT ON turismouq.v_aud_cambios_tarifa TO rol_auditor;
GRANT SELECT ON turismouq.v_aud_pagos          TO rol_auditor;

-- Portal del huesped: catalogo y su paquete
GRANT SELECT ON turismouq.municipio               TO rol_portal_web;
GRANT SELECT ON turismouq.tipo_alojamiento        TO rol_portal_web;
GRANT SELECT ON turismouq.v_catalogo_alojamientos TO rol_portal_web;
GRANT SELECT ON turismouq.v_catalogo_habitaciones TO rol_portal_web;
GRANT SELECT ON turismouq.v_catalogo_servicios    TO rol_portal_web;
GRANT SELECT ON turismouq.v_catalogo_tarifas      TO rol_portal_web;
GRANT EXECUTE ON turismouq.pkg_portal             TO rol_portal_web;


-- =====================================================================
-- USUARIOS
-- Sin cuota en ningun tablespace: no pueden crear tablas ni guardar datos
-- propios. Solo CREATE SESSION y el rol de su cargo.
-- =====================================================================
CREATE USER recep001 IDENTIFIED BY "Recepcion.2026" PROFILE perfil_turismouq;
CREATE USER recep013 IDENTIFIED BY "Recepcion.2026" PROFILE perfil_turismouq;
CREATE USER admin001 IDENTIFIED BY "Admin.2026"     PROFILE perfil_turismouq;
CREATE USER gerente1 IDENTIFIED BY "Gerente.2026"   PROFILE perfil_turismouq;
CREATE USER auditor1 IDENTIFIED BY "Auditor.2026"   PROFILE perfil_turismouq;
CREATE USER portal_web IDENTIFIED BY "PortalWeb.2026" PROFILE perfil_portal;

GRANT CREATE SESSION TO recep001, recep013, admin001, gerente1, auditor1, portal_web;

GRANT rol_recepcion         TO recep001, recep013;
GRANT rol_admin_alojamiento TO admin001;
GRANT rol_gerente           TO gerente1;
GRANT rol_auditor           TO auditor1;
GRANT rol_portal_web        TO portal_web;


SET LINESIZE 140;
SET PAGESIZE 80;
COLUMN usuario  FORMAT A10
COLUMN rol      FORMAT A22
COLUMN perfil   FORMAT A18
COLUMN resource_name FORMAT A24
COLUMN limit    FORMAT A12

PROMPT Usuarios, su rol y su perfil:
SELECT u.username AS usuario, r.granted_role AS rol, u.profile AS perfil, u.account_status
FROM   dba_users u
JOIN   dba_role_privs r ON r.grantee = u.username
WHERE  u.username IN ('RECEP001', 'RECEP013', 'ADMIN001', 'GERENTE1', 'AUDITOR1', 'PORTAL_WEB')
ORDER  BY r.granted_role, u.username;

PROMPT Limites del perfil:
SELECT resource_name, limit
FROM   dba_profiles
WHERE  profile = 'PERFIL_TURISMOUQ'
  AND  resource_name IN ('SESSIONS_PER_USER', 'IDLE_TIME', 'CONNECT_TIME',
                         'FAILED_LOGIN_ATTEMPTS', 'PASSWORD_LOCK_TIME', 'PASSWORD_LIFE_TIME')
ORDER  BY resource_name;

PROMPT Cuantos privilegios tiene cada rol, por tipo:
COLUMN privilegio FORMAT A10
SELECT grantee AS rol, privilege AS privilegio, COUNT(*) AS objetos
FROM   dba_tab_privs
WHERE  grantee IN ('ROL_RECEPCION', 'ROL_ADMIN_ALOJAMIENTO', 'ROL_GERENTE', 'ROL_AUDITOR',
                   'ROL_PORTAL_WEB')
GROUP  BY grantee, privilege
ORDER  BY grantee, privilege;
