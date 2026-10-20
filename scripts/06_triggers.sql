-- TurismoUQ - Script 06: disparadores de la Entrega 2
-- Ejecutar como TURISMOUQ despues del script 05

SET DEFINE OFF;

-- Disparador a nivel de fila: impide guardar una habitacion en una reserva
-- si otra reserva activa de esa misma habitacion se cruza en las fechas.
-- Es la misma regla que valida sp_crear_reserva, pero aqui tambien protege
-- a quien inserte directo en la tabla sin pasar por el procedimiento.
CREATE OR REPLACE TRIGGER trg_reserva_sin_cruce
BEFORE INSERT ON reserva_habitacion
FOR EACH ROW
DECLARE
  v_entrada  reserva.fecha_checkin%TYPE;
  v_salida   reserva.fecha_checkout%TYPE;
  v_estado   reserva.estado%TYPE;
  v_cruces   NUMBER;
BEGIN
  -- Fechas y estado de la reserva a la que pertenece la fila nueva
  SELECT fecha_checkin, fecha_checkout, estado
  INTO   v_entrada, v_salida, v_estado
  FROM   reserva
  WHERE  id_reserva = :NEW.id_reserva;

  -- Una reserva cancelada no ocupa la habitacion, no hay nada que revisar
  IF v_estado <> 'CANCELADA' THEN

    -- Otras reservas activas de la misma habitacion que se crucen.
    -- Se excluye la misma reserva porque una estadia que cruza dos
    -- temporadas guarda dos filas para la misma habitacion.
    SELECT COUNT(*)
    INTO   v_cruces
    FROM   reserva_habitacion rh
    JOIN   reserva r ON r.id_reserva = rh.id_reserva
    WHERE  rh.id_habitacion  = :NEW.id_habitacion
      AND  rh.id_reserva    <> :NEW.id_reserva
      AND  r.estado         <> 'CANCELADA'
      AND  r.fecha_checkin   < v_salida
      AND  r.fecha_checkout  > v_entrada;

    IF v_cruces > 0 THEN
      RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_no_disponible,
        'La habitacion ' || :NEW.id_habitacion || ' ya esta reservada entre el '
        || TO_CHAR(v_entrada, 'DD/MM/YYYY') || ' y el '
        || TO_CHAR(v_salida, 'DD/MM/YYYY') || '.');
    END IF;

  END IF;
END trg_reserva_sin_cruce;
/
SHOW ERRORS TRIGGER trg_reserva_sin_cruce


-- Disparador a nivel de fila sobre RESERVA: completa al anterior.
-- trg_reserva_sin_cruce revisa las habitaciones que se registran, pero una
-- reserva tambien podria quedar cruzada si se le cambian las fechas o si se
-- reactiva una que estaba cancelada. Este disparador lo impide:
--   - las fechas de una reserva no se cambian: se cancela y se crea otra,
--     y asi la nueva pasa por todas las validaciones de sp_crear_reserva.
--   - una reserva CANCELADA o FINALIZADA ya no cambia de estado.
-- Solo compara el valor viejo con el nuevo y no consulta ninguna tabla, por
-- eso no tiene el problema de tabla mutante.
CREATE OR REPLACE TRIGGER trg_reserva_cambios
BEFORE UPDATE OF fecha_checkin, fecha_checkout, estado ON reserva
FOR EACH ROW
BEGIN
  IF :NEW.fecha_checkin <> :OLD.fecha_checkin
     OR :NEW.fecha_checkout <> :OLD.fecha_checkout THEN
    RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_reserva,
      'Las fechas de la reserva ' || :OLD.id_reserva || ' no se pueden cambiar. '
      || 'Cancele la reserva y cree una nueva.');
  END IF;

  IF :OLD.estado IN ('CANCELADA', 'FINALIZADA') AND :NEW.estado <> :OLD.estado THEN
    RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_reserva,
      'La reserva ' || :OLD.id_reserva || ' esta ' || :OLD.estado
      || ' y ya no puede cambiar de estado.');
  END IF;
END trg_reserva_cambios;
/
SHOW ERRORS TRIGGER trg_reserva_cambios


-- Disparador a nivel de sentencia: auditoria de cambios en TARIFA.
-- Un disparador de sentencia no puede ver el valor anterior ni el nuevo de
-- cada fila, por eso es un disparador compuesto:
--   AFTER EACH ROW  anota cada cambio en una lista en memoria.
--   AFTER STATEMENT al terminar la sentencia guarda toda la lista en la
--                   tabla de auditoria, una sola vez por sentencia.
CREATE OR REPLACE TRIGGER trg_auditoria_tarifa
FOR INSERT OR UPDATE OF valor_noche OR DELETE ON tarifa
COMPOUND TRIGGER

  TYPE t_cambio IS RECORD (
    id_tarifa       tarifa.id_tarifa%TYPE,
    id_habitacion   tarifa.id_habitacion%TYPE,
    id_temporada    tarifa.id_temporada%TYPE,
    operacion       VARCHAR2(6),
    valor_anterior  tarifa.valor_noche%TYPE,
    valor_nuevo     tarifa.valor_noche%TYPE
  );
  TYPE t_lista IS TABLE OF t_cambio INDEX BY PLS_INTEGER;

  v_cambios  t_lista;
  v_i        PLS_INTEGER;

  -- Por cada fila afectada: anotar el cambio
  AFTER EACH ROW IS
  BEGIN
    v_i := v_cambios.COUNT + 1;
    v_cambios(v_i).id_tarifa      := NVL(:NEW.id_tarifa,     :OLD.id_tarifa);
    v_cambios(v_i).id_habitacion  := NVL(:NEW.id_habitacion, :OLD.id_habitacion);
    v_cambios(v_i).id_temporada   := NVL(:NEW.id_temporada,  :OLD.id_temporada);
    v_cambios(v_i).valor_anterior := :OLD.valor_noche;
    v_cambios(v_i).valor_nuevo    := :NEW.valor_noche;

    IF INSERTING THEN
      v_cambios(v_i).operacion := 'INSERT';
    ELSIF UPDATING THEN
      v_cambios(v_i).operacion := 'UPDATE';
    ELSE
      v_cambios(v_i).operacion := 'DELETE';
    END IF;
  END AFTER EACH ROW;

  -- Al terminar la sentencia: guardar todos los cambios anotados.
  -- Quien y cuando se llenan solos con los valores por defecto de la tabla.
  AFTER STATEMENT IS
  BEGIN
    FOR i IN 1 .. v_cambios.COUNT LOOP
      INSERT INTO auditoria_tarifa (id_auditoria, id_tarifa, id_habitacion, id_temporada,
                                    operacion, valor_anterior, valor_nuevo)
      VALUES (seq_auditoria_tarifa.NEXTVAL, v_cambios(i).id_tarifa,
              v_cambios(i).id_habitacion, v_cambios(i).id_temporada,
              v_cambios(i).operacion, v_cambios(i).valor_anterior,
              v_cambios(i).valor_nuevo);
    END LOOP;
  END AFTER STATEMENT;

END trg_auditoria_tarifa;
/
SHOW ERRORS TRIGGER trg_auditoria_tarifa


SET LINESIZE 100;
SET PAGESIZE 50;
SET TAB OFF;
COLUMN trigger_name  FORMAT A24
COLUMN trigger_type  FORMAT A20
COLUMN table_name    FORMAT A20
COLUMN status        FORMAT A8

PROMPT Disparadores creados:
SELECT trigger_name, trigger_type, table_name, status
FROM   user_triggers
WHERE  trigger_name IN ('TRG_RESERVA_SIN_CRUCE', 'TRG_RESERVA_CAMBIOS', 'TRG_AUDITORIA_TARIFA')
ORDER  BY trigger_name;
