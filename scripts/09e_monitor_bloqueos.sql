-- TurismoUQ - Experimento de concurrencia, paso 9 (monitoreo)
-- Se ejecuta en la sesion A mientras la sesion B esta esperando.
-- Muestra las sesiones del proyecto, cual esta bloqueada y por quien, y
-- sobre que tabla hay bloqueos.

SET LINESIZE 160;
SET PAGESIZE 50;
COLUMN username FORMAT A12
COLUMN status   FORMAT A9
COLUMN event    FORMAT A42
COLUMN object_name FORMAT A22
COLUMN modo     FORMAT A20

PROMPT Sesiones de TURISMOUQ (BLOCKING_SESSION dice a que sesion esta esperando):
SELECT sid, serial#, username, status, blocking_session, event, seconds_in_wait
FROM   v$session
WHERE  username = 'TURISMOUQ'
ORDER  BY sid;

PROMPT Bloqueos activos por objeto:
SELECT s.sid, s.username, o.object_name,
       DECODE(l.locked_mode, 2, 'ROW SHARE (RS)', 3, 'ROW EXCLUSIVE (RX)',
                             4, 'SHARE (S)', 5, 'SHARE ROW EXCL (SRX)',
                             6, 'EXCLUSIVE (X)', l.locked_mode) AS modo
FROM   v$locked_object l
JOIN   v$session s   ON s.sid       = l.session_id
JOIN   dba_objects o ON o.object_id = l.object_id
WHERE  s.username = 'TURISMOUQ'
ORDER  BY s.sid, o.object_name;
