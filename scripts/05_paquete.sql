-- TurismoUQ - Script 05: paquete PKG_TURISMOUQ (logica PL/SQL de la Entrega 2)
-- Ejecutar como TURISMOUQ despues del script 04

SET DEFINE OFF;

-- Especificacion del paquete
CREATE OR REPLACE PACKAGE pkg_turismouq IS

  -- Codigos de error propios (rango -20000 a -20999 de RAISE_APPLICATION_ERROR)
  c_err_no_disponible  CONSTANT PLS_INTEGER := -20001;  -- habitacion ocupada o fuera de servicio
  c_err_fechas         CONSTANT PLS_INTEGER := -20002;  -- checkout anterior o igual al checkin
  c_err_capacidad      CONSTANT PLS_INTEGER := -20003;  -- mas huespedes que la capacidad
  c_err_habitacion     CONSTANT PLS_INTEGER := -20004;  -- la habitacion no existe
  c_err_tarifa         CONSTANT PLS_INTEGER := -20005;  -- noches sin temporada o sin tarifa
  c_err_cliente        CONSTANT PLS_INTEGER := -20006;  -- cliente inexistente o con datos incompletos
  c_err_liquidacion    CONSTANT PLS_INTEGER := -20007;  -- mes ya liquidado, sin terminar o comision invalida
  c_err_reserva        CONSTANT PLS_INTEGER := -20008;  -- reserva inexistente o en un estado que no permite la operacion
  c_err_duplicado      CONSTANT PLS_INTEGER := -20009;  -- cliente con documento o correo ya registrado
  c_err_servicio       CONSTANT PLS_INTEGER := -20010;  -- servicio inexistente o de otro alojamiento
  c_err_dato_invalido  CONSTANT PLS_INTEGER := -20011;  -- valor fuera de rango o no permitido
  c_err_temporada_iniciada CONSTANT PLS_INTEGER := -20012;  -- tarifa de una temporada que ya empezo

  -- Valor de una estadia cobrando cada noche con la tarifa de su temporada
  FUNCTION fn_valor_estadia (
    p_id_habitacion  IN habitacion.id_habitacion%TYPE,
    p_fecha_in       IN reserva.fecha_checkin%TYPE,
    p_fecha_out      IN reserva.fecha_checkout%TYPE
  ) RETURN NUMBER;

  -- TRUE si la habitacion no tiene reservas que se crucen con esas fechas
  FUNCTION fn_habitacion_disponible (
    p_id_habitacion  IN habitacion.id_habitacion%TYPE,
    p_fecha_in       IN reserva.fecha_checkin%TYPE,
    p_fecha_out      IN reserva.fecha_checkout%TYPE
  ) RETURN BOOLEAN;

  -- Crea la reserva de una habitacion y devuelve su numero en p_id_reserva
  PROCEDURE sp_crear_reserva (
    p_id_cliente     IN  cliente.id_cliente%TYPE,
    p_id_habitacion  IN  habitacion.id_habitacion%TYPE,
    p_fecha_in       IN  reserva.fecha_checkin%TYPE,
    p_fecha_out      IN  reserva.fecha_checkout%TYPE,
    p_num_huespedes  IN  reserva.num_huespedes%TYPE,
    p_id_reserva     OUT reserva.id_reserva%TYPE
  );

  -- Liquida un mes: lo que la plataforma le paga a cada alojamiento,
  -- descontando su comision (12% si no se indica otra)
  PROCEDURE sp_liquidar_mes (
    p_periodo     IN DATE,
    p_porcentaje  IN NUMBER DEFAULT 12
  );

  -- Muestra la liquidacion de un mes alojamiento por alojamiento, con cada
  -- reserva que entro en ella. Si no se indica alojamiento, muestra todos.
  PROCEDURE sp_reporte_liquidacion (
    p_periodo         IN DATE,
    p_id_alojamiento  IN alojamiento.id_alojamiento%TYPE DEFAULT NULL
  );

  -- Registra un cliente nuevo y devuelve su numero en p_id_cliente
  PROCEDURE sp_registrar_cliente (
    p_nombre      IN  cliente.nombre%TYPE,
    p_documento   IN  cliente.documento%TYPE,
    p_email       IN  cliente.email%TYPE,
    p_id_cliente  OUT cliente.id_cliente%TYPE
  );

  -- Carga un servicio consumido a una reserva confirmada
  PROCEDURE sp_agregar_servicio (
    p_id_reserva   IN reserva.id_reserva%TYPE,
    p_id_servicio  IN servicio.id_servicio%TYPE,
    p_cantidad     IN reserva_servicio.cantidad%TYPE
  );

  -- Cierra la estadia: cobra lo que falte por pagar y la deja FINALIZADA
  PROCEDURE sp_checkout (
    p_id_reserva   IN reserva.id_reserva%TYPE,
    p_metodo_pago  IN pago.metodo_pago%TYPE DEFAULT 'TARJETA_CREDITO'
  );

  -- Cancela una reserva confirmada que todavia no ha empezado
  PROCEDURE sp_cancelar_reserva (
    p_id_reserva   IN reserva.id_reserva%TYPE
  );

  -- Cambia la tarifa por noche de una temporada que todavia no empieza
  PROCEDURE sp_actualizar_tarifa (
    p_id_tarifa    IN tarifa.id_tarifa%TYPE,
    p_valor_noche  IN tarifa.valor_noche%TYPE
  );

  -- Sube o baja en un porcentaje todas las tarifas de un alojamiento en las
  -- temporadas de un ano que todavia no empiezan; devuelve cuantas cambio
  PROCEDURE sp_ajustar_tarifas (
    p_id_alojamiento  IN  alojamiento.id_alojamiento%TYPE,
    p_anio            IN  NUMBER,
    p_porcentaje      IN  NUMBER,
    p_afectadas       OUT NUMBER
  );

  -- Pone una habitacion DISPONIBLE, en MANTENIMIENTO o INACTIVA
  PROCEDURE sp_cambiar_estado_habitacion (
    p_id_habitacion  IN habitacion.id_habitacion%TYPE,
    p_estado         IN habitacion.estado%TYPE
  );

  -- Borra la liquidacion de un mes para poder volver a liquidarlo
  PROCEDURE sp_reabrir_liquidacion (
    p_periodo  IN DATE
  );

END pkg_turismouq;
/
SHOW ERRORS PACKAGE pkg_turismouq

-- Cuerpo del paquete
CREATE OR REPLACE PACKAGE BODY pkg_turismouq IS

  -- fn_valor_estadia
  -- 1. Valida fechas y habitacion.
  -- 2. Recorre con un cursor las temporadas que se cruzan con la estadia.
  -- 3. Suma noches x tarifa de cada temporada.
  -- 4. Si alguna noche queda sin tarifa lanza error en vez de devolver 0.
  FUNCTION fn_valor_estadia (
    p_id_habitacion  IN habitacion.id_habitacion%TYPE,
    p_fecha_in       IN reserva.fecha_checkin%TYPE,
    p_fecha_out      IN reserva.fecha_checkout%TYPE
  ) RETURN NUMBER
  IS
    -- Temporadas que se cruzan con la estadia y la tarifa de la habitacion
    -- en cada una. LEFT JOIN para detectar una temporada sin tarifa.
    CURSOR c_tramos (p_hab NUMBER, p_entrada DATE, p_salida DATE) IS
      SELECT t.nombre       AS temporada,
             tf.valor_noche AS valor_noche,
             LEAST(p_salida - 1, t.fecha_fin)
               - GREATEST(p_entrada, t.fecha_inicio) + 1 AS noches
      FROM   temporada t
      LEFT   JOIN tarifa tf ON tf.id_temporada  = t.id_temporada
                           AND tf.id_habitacion = p_hab
      WHERE  t.fecha_inicio <= p_salida - 1
        AND  t.fecha_fin    >= p_entrada
      ORDER  BY t.fecha_inicio;

    r_tramo              c_tramos%ROWTYPE;
    v_entrada            DATE := TRUNC(p_fecha_in);
    v_salida             DATE := TRUNC(p_fecha_out);
    v_total              NUMBER := 0;
    v_noches_cubiertas   NUMBER := 0;
    v_existe             NUMBER;
  BEGIN
    -- 1. Validaciones
    IF v_entrada IS NULL OR v_salida IS NULL THEN
      RAISE_APPLICATION_ERROR(c_err_fechas,
        'Las fechas de entrada y salida son obligatorias.');
    END IF;

    IF v_salida <= v_entrada THEN
      RAISE_APPLICATION_ERROR(c_err_fechas,
        'La fecha de salida (' || TO_CHAR(v_salida, 'DD/MM/YYYY')
        || ') debe ser posterior a la de entrada ('
        || TO_CHAR(v_entrada, 'DD/MM/YYYY') || ').');
    END IF;

    SELECT COUNT(*)
    INTO   v_existe
    FROM   habitacion
    WHERE  id_habitacion = p_id_habitacion;

    IF v_existe = 0 THEN
      RAISE_APPLICATION_ERROR(c_err_habitacion,
        'La habitacion ' || p_id_habitacion || ' no existe.');
    END IF;

    -- 2 y 3. Recorrer las temporadas de la estadia
    OPEN c_tramos(p_id_habitacion, v_entrada, v_salida);
    LOOP
      FETCH c_tramos INTO r_tramo;
      EXIT WHEN c_tramos%NOTFOUND;

      IF r_tramo.valor_noche IS NULL THEN
        RAISE_APPLICATION_ERROR(c_err_tarifa,
          'La habitacion ' || p_id_habitacion
          || ' no tiene tarifa para la temporada ' || r_tramo.temporada || '.');
      END IF;

      v_total            := v_total + r_tramo.noches * r_tramo.valor_noche;
      v_noches_cubiertas := v_noches_cubiertas + r_tramo.noches;
    END LOOP;
    CLOSE c_tramos;

    -- 4. Todas las noches deben tener temporada
    IF v_noches_cubiertas <> v_salida - v_entrada THEN
      RAISE_APPLICATION_ERROR(c_err_tarifa,
        'Hay noches entre el ' || TO_CHAR(v_entrada, 'DD/MM/YYYY')
        || ' y el ' || TO_CHAR(v_salida, 'DD/MM/YYYY')
        || ' que no pertenecen a ninguna temporada definida.');
    END IF;

    RETURN v_total;

  EXCEPTION
    WHEN OTHERS THEN
      -- Cerrar el cursor si quedo abierto y volver a lanzar el error
      IF c_tramos%ISOPEN THEN
        CLOSE c_tramos;
      END IF;
      RAISE;
  END fn_valor_estadia;


  -- fn_habitacion_disponible
  -- Dos estadias se cruzan si una entra antes de que la otra salga y sale
  -- despues de que la otra entra. Salir el mismo dia que otro entra no es cruce.
  -- Las reservas canceladas no ocupan la habitacion.
  FUNCTION fn_habitacion_disponible (
    p_id_habitacion  IN habitacion.id_habitacion%TYPE,
    p_fecha_in       IN reserva.fecha_checkin%TYPE,
    p_fecha_out      IN reserva.fecha_checkout%TYPE
  ) RETURN BOOLEAN
  IS
    v_cruces NUMBER;
  BEGIN
    SELECT COUNT(*)
    INTO   v_cruces
    FROM   reserva r
    JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
    WHERE  rh.id_habitacion  = p_id_habitacion
      AND  r.estado         <> 'CANCELADA'
      AND  r.fecha_checkin   < TRUNC(p_fecha_out)
      AND  r.fecha_checkout  > TRUNC(p_fecha_in);

    RETURN v_cruces = 0;
  END fn_habitacion_disponible;


  -- sp_crear_reserva
  -- Valida los datos, calcula el valor con fn_valor_estadia y guarda la
  -- reserva con una fila en RESERVA_HABITACION por cada temporada de la estadia.
  PROCEDURE sp_crear_reserva (
    p_id_cliente     IN  cliente.id_cliente%TYPE,
    p_id_habitacion  IN  habitacion.id_habitacion%TYPE,
    p_fecha_in       IN  reserva.fecha_checkin%TYPE,
    p_fecha_out      IN  reserva.fecha_checkout%TYPE,
    p_num_huespedes  IN  reserva.num_huespedes%TYPE,
    p_id_reserva     OUT reserva.id_reserva%TYPE
  )
  IS
    v_entrada    DATE := TRUNC(p_fecha_in);
    v_salida     DATE := TRUNC(p_fecha_out);
    v_existe     NUMBER;
    v_estado     habitacion.estado%TYPE;
    v_capacidad  habitacion.capacidad%TYPE;
    v_valor      NUMBER;
  BEGIN
    -- 1. Fechas
    IF v_entrada IS NULL OR v_salida IS NULL OR v_salida <= v_entrada THEN
      RAISE_APPLICATION_ERROR(c_err_fechas,
        'La fecha de salida debe ser posterior a la fecha de entrada.');
    END IF;

    IF v_entrada < TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(c_err_fechas,
        'No se puede reservar con fecha de entrada en el pasado ('
        || TO_CHAR(v_entrada, 'DD/MM/YYYY') || ').');
    END IF;

    -- 2. Cliente
    SELECT COUNT(*)
    INTO   v_existe
    FROM   cliente
    WHERE  id_cliente = p_id_cliente;

    IF v_existe = 0 THEN
      RAISE_APPLICATION_ERROR(c_err_cliente,
        'El cliente ' || p_id_cliente || ' no existe.');
    END IF;

    -- 3. Habitacion: que exista, que este en servicio y que tenga capacidad
    BEGIN
      SELECT estado, capacidad
      INTO   v_estado, v_capacidad
      FROM   habitacion
      WHERE  id_habitacion = p_id_habitacion;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(c_err_habitacion,
          'La habitacion ' || p_id_habitacion || ' no existe.');
    END;

    IF v_estado <> 'DISPONIBLE' THEN
      RAISE_APPLICATION_ERROR(c_err_no_disponible,
        'La habitacion ' || p_id_habitacion || ' no se puede reservar, esta en '
        || v_estado || '.');
    END IF;

    IF p_num_huespedes IS NULL OR p_num_huespedes < 1 THEN
      RAISE_APPLICATION_ERROR(c_err_capacidad,
        'La reserva debe tener al menos un huesped.');
    END IF;

    IF p_num_huespedes > v_capacidad THEN
      RAISE_APPLICATION_ERROR(c_err_capacidad,
        'La habitacion ' || p_id_habitacion || ' es para ' || v_capacidad
        || ' personas y se pidio para ' || p_num_huespedes || '.');
    END IF;

    -- 4. Que la habitacion no este reservada en esas fechas
    IF NOT fn_habitacion_disponible(p_id_habitacion, v_entrada, v_salida) THEN
      RAISE_APPLICATION_ERROR(c_err_no_disponible,
        'La habitacion ' || p_id_habitacion || ' ya esta reservada entre el '
        || TO_CHAR(v_entrada, 'DD/MM/YYYY') || ' y el '
        || TO_CHAR(v_salida, 'DD/MM/YYYY') || '.');
    END IF;

    -- 5. Valor de la estadia
    v_valor := fn_valor_estadia(p_id_habitacion, v_entrada, v_salida);

    -- 6. Guardar la reserva y su detalle por temporada
    p_id_reserva := seq_reserva.NEXTVAL;

    INSERT INTO reserva (id_reserva, id_cliente, fecha_checkin, fecha_checkout,
                         estado, valor_total, num_huespedes)
    VALUES (p_id_reserva, p_id_cliente, v_entrada, v_salida,
            'CONFIRMADA', v_valor, p_num_huespedes);

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

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Reserva ' || p_id_reserva || ' creada. Valor: ' || v_valor);

  EXCEPTION
    WHEN OTHERS THEN
      -- Deshace lo que alcanzo a guardar y devuelve el error a quien llamo
      ROLLBACK;
      RAISE;
  END sp_crear_reserva;


  -- sp_liquidar_mes
  -- Se liquidan las estadias FINALIZADAS cuya fecha de salida cae en el mes.
  -- Por cada alojamiento: ingresos de alojamiento y de servicios, comision de
  -- la plataforma y valor a pagar, y el detalle de cada una de sus reservas.
  -- O se liquida todo el mes o no se liquida nada.
  PROCEDURE sp_liquidar_mes (
    p_periodo     IN DATE,
    p_porcentaje  IN NUMBER DEFAULT 12
  )
  IS
    -- Cursor explicito con parametros: una fila por alojamiento con lo que
    -- vendio en las estadias finalizadas que salieron entre p_desde y p_hasta
    CURSOR c_alojamientos (p_desde DATE, p_hasta DATE) IS
      SELECT h.id_alojamiento,
             COUNT(DISTINCT r.id_reserva)              AS reservas,
             SUM(rh.noches)                            AS noches,
             SUM(rh.noches * rh.valor_noche_aplicado)  AS ingreso_alojamiento
      FROM   reserva r
      JOIN   reserva_habitacion rh ON rh.id_reserva   = r.id_reserva
      JOIN   habitacion h          ON h.id_habitacion = rh.id_habitacion
      WHERE  r.estado = 'FINALIZADA'
        AND  r.fecha_checkout >= p_desde
        AND  r.fecha_checkout <  p_hasta
      GROUP  BY h.id_alojamiento
      ORDER  BY h.id_alojamiento;

    -- Segundo cursor explicito con parametros: las reservas de UN alojamiento
    -- que entran en la liquidacion, cada una con lo que pago de alojamiento
    -- y de servicios. Se abre una vez por cada alojamiento del cursor anterior.
    CURSOR c_reservas (p_aloj NUMBER, p_desde DATE, p_hasta DATE) IS
      SELECT r.id_reserva,
             r.id_cliente,
             r.fecha_checkin,
             r.fecha_checkout,
             SUM(rh.noches)                            AS noches,
             SUM(rh.noches * rh.valor_noche_aplicado)  AS valor_alojamiento,
             NVL((SELECT SUM(rs.valor_total)
                  FROM   reserva_servicio rs
                  JOIN   servicio s ON s.id_servicio = rs.id_servicio
                  WHERE  rs.id_reserva     = r.id_reserva
                    AND  s.id_alojamiento  = p_aloj), 0) AS valor_servicios
      FROM   reserva r
      JOIN   reserva_habitacion rh ON rh.id_reserva   = r.id_reserva
      JOIN   habitacion h          ON h.id_habitacion = rh.id_habitacion
      WHERE  h.id_alojamiento = p_aloj
        AND  r.estado = 'FINALIZADA'
        AND  r.fecha_checkout >= p_desde
        AND  r.fecha_checkout <  p_hasta
      GROUP  BY r.id_reserva, r.id_cliente, r.fecha_checkin, r.fecha_checkout
      ORDER  BY r.fecha_checkout, r.id_reserva;

    r_aloj        c_alojamientos%ROWTYPE;
    r_reserva     c_reservas%ROWTYPE;
    v_detalles    NUMBER := 0;
    v_desde       DATE := TRUNC(p_periodo, 'MM');
    v_hasta       DATE := ADD_MONTHS(TRUNC(p_periodo, 'MM'), 1);
    v_existe      NUMBER;
    v_servicios   NUMBER;
    v_comision    NUMBER;
    v_pagar       NUMBER;
    v_total       NUMBER := 0;
    v_liquidados  NUMBER := 0;
  BEGIN
    -- 1. Validaciones
    IF p_periodo IS NULL THEN
      RAISE_APPLICATION_ERROR(c_err_liquidacion, 'Debe indicar el mes a liquidar.');
    END IF;

    IF v_hasta > TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(c_err_liquidacion,
        'El mes ' || TO_CHAR(v_desde, 'MM/YYYY') || ' todavia no ha terminado.');
    END IF;

    IF p_porcentaje IS NULL OR p_porcentaje < 0 OR p_porcentaje > 100 THEN
      RAISE_APPLICATION_ERROR(c_err_liquidacion,
        'El porcentaje de comision debe estar entre 0 y 100.');
    END IF;

    SELECT COUNT(*)
    INTO   v_existe
    FROM   liquidacion_mensual
    WHERE  periodo = v_desde;

    IF v_existe > 0 THEN
      RAISE_APPLICATION_ERROR(c_err_liquidacion,
        'El mes ' || TO_CHAR(v_desde, 'MM/YYYY') || ' ya fue liquidado.');
    END IF;

    -- 2. Recorrer los alojamientos que tuvieron ventas en el mes
    OPEN c_alojamientos(v_desde, v_hasta);
    LOOP
      FETCH c_alojamientos INTO r_aloj;
      EXIT WHEN c_alojamientos%NOTFOUND;

      -- Servicios consumidos en esas mismas estadias
      SELECT NVL(SUM(rs.valor_total), 0)
      INTO   v_servicios
      FROM   reserva_servicio rs
      JOIN   servicio s ON s.id_servicio = rs.id_servicio
      JOIN   reserva  r ON r.id_reserva  = rs.id_reserva
      WHERE  s.id_alojamiento = r_aloj.id_alojamiento
        AND  r.estado = 'FINALIZADA'
        AND  r.fecha_checkout >= v_desde
        AND  r.fecha_checkout <  v_hasta;

      v_comision := ROUND((r_aloj.ingreso_alojamiento + v_servicios) * p_porcentaje / 100, 2);
      v_pagar    := r_aloj.ingreso_alojamiento + v_servicios - v_comision;

      INSERT INTO liquidacion_mensual (id_alojamiento, periodo, reservas, noches_vendidas,
                                       ingreso_alojamiento, ingreso_servicios,
                                       porcentaje_comision, valor_comision, valor_a_pagar)
      VALUES (r_aloj.id_alojamiento, v_desde, r_aloj.reservas, r_aloj.noches,
              r_aloj.ingreso_alojamiento, v_servicios,
              p_porcentaje, v_comision, v_pagar);

      -- Detalle: cada reserva del alojamiento, una por una
      OPEN c_reservas(r_aloj.id_alojamiento, v_desde, v_hasta);
      LOOP
        FETCH c_reservas INTO r_reserva;
        EXIT WHEN c_reservas%NOTFOUND;

        INSERT INTO liquidacion_detalle (id_alojamiento, periodo, id_reserva, id_cliente,
                                         fecha_checkin, fecha_checkout, noches,
                                         valor_alojamiento, valor_servicios, valor_total)
        VALUES (r_aloj.id_alojamiento, v_desde, r_reserva.id_reserva, r_reserva.id_cliente,
                r_reserva.fecha_checkin, r_reserva.fecha_checkout, r_reserva.noches,
                r_reserva.valor_alojamiento, r_reserva.valor_servicios,
                r_reserva.valor_alojamiento + r_reserva.valor_servicios);
      END LOOP;
      v_detalles := v_detalles + c_reservas%ROWCOUNT;
      CLOSE c_reservas;

      v_total := v_total + v_pagar;
    END LOOP;
    v_liquidados := c_alojamientos%ROWCOUNT;
    CLOSE c_alojamientos;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Mes ' || TO_CHAR(v_desde, 'MM/YYYY') || ' liquidado: '
                         || v_liquidados || ' alojamientos, ' || v_detalles
                         || ' reservas, total a pagar ' || v_total);

  EXCEPTION
    WHEN OTHERS THEN
      -- Cierra los cursores que hayan quedado abiertos, deshace todo y
      -- devuelve el error
      IF c_reservas%ISOPEN THEN
        CLOSE c_reservas;
      END IF;
      IF c_alojamientos%ISOPEN THEN
        CLOSE c_alojamientos;
      END IF;
      ROLLBACK;
      RAISE;
  END sp_liquidar_mes;


  -- sp_reporte_liquidacion
  -- Solo consulta: recorre los alojamientos liquidados del mes y, por cada
  -- uno, sus reservas. Imprime cada reserva con su valor y al final el
  -- subtotal, la comision y lo que se le paga al alojamiento.
  PROCEDURE sp_reporte_liquidacion (
    p_periodo         IN DATE,
    p_id_alojamiento  IN alojamiento.id_alojamiento%TYPE DEFAULT NULL
  )
  IS
    CURSOR c_liquidados (p_per DATE, p_aloj NUMBER) IS
      SELECT l.id_alojamiento, a.nombre AS alojamiento, m.nombre AS municipio,
             l.reservas, l.ingreso_alojamiento, l.ingreso_servicios,
             l.porcentaje_comision, l.valor_comision, l.valor_a_pagar
      FROM   liquidacion_mensual l
      JOIN   alojamiento a ON a.id_alojamiento = l.id_alojamiento
      JOIN   municipio m   ON m.id_municipio   = a.id_municipio
      WHERE  l.periodo = p_per
        AND  (p_aloj IS NULL OR l.id_alojamiento = p_aloj)
      ORDER  BY a.nombre;

    CURSOR c_facturas (p_aloj NUMBER, p_per DATE) IS
      SELECT d.id_reserva, c.nombre AS cliente, d.fecha_checkin, d.fecha_checkout,
             d.noches, d.valor_alojamiento, d.valor_servicios, d.valor_total
      FROM   liquidacion_detalle d
      JOIN   cliente c ON c.id_cliente = d.id_cliente
      WHERE  d.id_alojamiento = p_aloj
        AND  d.periodo        = p_per
      ORDER  BY d.fecha_checkout, d.id_reserva;

    r_liq      c_liquidados%ROWTYPE;
    r_fac      c_facturas%ROWTYPE;
    v_periodo  DATE := TRUNC(p_periodo, 'MM');

    FUNCTION fn_dinero (p_valor NUMBER) RETURN VARCHAR2 IS
    BEGIN
      RETURN LPAD(TO_CHAR(p_valor, 'FM999G999G999'), 12);
    END fn_dinero;
  BEGIN
    OPEN c_liquidados(v_periodo, p_id_alojamiento);
    LOOP
      FETCH c_liquidados INTO r_liq;
      EXIT WHEN c_liquidados%NOTFOUND;

      DBMS_OUTPUT.PUT_LINE(RPAD('=', 92, '='));
      DBMS_OUTPUT.PUT_LINE(r_liq.alojamiento || ' (' || r_liq.municipio || ') - liquidacion de '
                           || TO_CHAR(v_periodo, 'MM/YYYY') || ' - ' || r_liq.reservas || ' reservas');
      DBMS_OUTPUT.PUT_LINE(RPAD('Reserva', 9) || RPAD('Cliente', 22) || RPAD('Entrada', 11)
                           || RPAD('Salida', 11) || LPAD('Noches', 6)
                           || LPAD('Alojamiento', 12) || LPAD('Servicios', 12) || LPAD('Total', 12));

      OPEN c_facturas(r_liq.id_alojamiento, v_periodo);
      LOOP
        FETCH c_facturas INTO r_fac;
        EXIT WHEN c_facturas%NOTFOUND;
        DBMS_OUTPUT.PUT_LINE(RPAD(r_fac.id_reserva, 9) || RPAD(SUBSTR(r_fac.cliente, 1, 21), 22)
                             || RPAD(TO_CHAR(r_fac.fecha_checkin, 'DD/MM/YYYY'), 11)
                             || RPAD(TO_CHAR(r_fac.fecha_checkout, 'DD/MM/YYYY'), 11)
                             || LPAD(r_fac.noches, 6)
                             || fn_dinero(r_fac.valor_alojamiento)
                             || fn_dinero(r_fac.valor_servicios)
                             || fn_dinero(r_fac.valor_total));
      END LOOP;
      CLOSE c_facturas;

      DBMS_OUTPUT.PUT_LINE(RPAD('Subtotal', 59, '.')
                           || fn_dinero(r_liq.ingreso_alojamiento)
                           || fn_dinero(r_liq.ingreso_servicios)
                           || fn_dinero(r_liq.ingreso_alojamiento + r_liq.ingreso_servicios));
      DBMS_OUTPUT.PUT_LINE(RPAD('Comision de TurismoUQ (' || r_liq.porcentaje_comision || '%)', 83, '.')
                           || fn_dinero(r_liq.valor_comision));
      DBMS_OUTPUT.PUT_LINE(RPAD('A pagar al alojamiento', 83, '.')
                           || fn_dinero(r_liq.valor_a_pagar));
    END LOOP;

    IF c_liquidados%ROWCOUNT = 0 THEN
      CLOSE c_liquidados;
      RAISE_APPLICATION_ERROR(c_err_liquidacion,
        'El mes ' || TO_CHAR(v_periodo, 'MM/YYYY') || ' no esta liquidado'
        || CASE WHEN p_id_alojamiento IS NOT NULL
                THEN ' para el alojamiento ' || p_id_alojamiento END || '.');
    END IF;
    CLOSE c_liquidados;

  EXCEPTION
    WHEN OTHERS THEN
      IF c_facturas%ISOPEN THEN
        CLOSE c_facturas;
      END IF;
      IF c_liquidados%ISOPEN THEN
        CLOSE c_liquidados;
      END IF;
      RAISE;
  END sp_reporte_liquidacion;


  -- sp_registrar_cliente
  -- Si el documento o el correo ya existen, las restricciones UNIQUE de la
  -- tabla hacen que Oracle lance la excepcion predefinida DUP_VAL_ON_INDEX,
  -- que aqui se cambia por un error propio con un mensaje claro.
  PROCEDURE sp_registrar_cliente (
    p_nombre      IN  cliente.nombre%TYPE,
    p_documento   IN  cliente.documento%TYPE,
    p_email       IN  cliente.email%TYPE,
    p_id_cliente  OUT cliente.id_cliente%TYPE
  )
  IS
  BEGIN
    IF TRIM(p_nombre) IS NULL OR TRIM(p_documento) IS NULL OR TRIM(p_email) IS NULL THEN
      RAISE_APPLICATION_ERROR(c_err_cliente,
        'El nombre, el documento y el correo del cliente son obligatorios.');
    END IF;

    IF INSTR(p_email, '@') = 0 OR INSTR(p_email, '.') = 0 THEN
      RAISE_APPLICATION_ERROR(c_err_cliente,
        'El correo ' || p_email || ' no es valido.');
    END IF;

    p_id_cliente := seq_cliente.NEXTVAL;

    INSERT INTO cliente (id_cliente, nombre, documento, email)
    VALUES (p_id_cliente, TRIM(p_nombre), TRIM(p_documento), LOWER(TRIM(p_email)));

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Cliente ' || p_id_cliente || ' registrado.');

  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      ROLLBACK;
      RAISE_APPLICATION_ERROR(c_err_duplicado,
        'Ya existe un cliente registrado con el documento ' || TRIM(p_documento)
        || ' o con el correo ' || LOWER(TRIM(p_email)) || '.');
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END sp_registrar_cliente;


  -- sp_agregar_servicio
  -- Solo a reservas CONFIRMADAS, y solo servicios del mismo alojamiento donde
  -- esta hospedado el cliente. El consumo se suma al valor total de la reserva.
  PROCEDURE sp_agregar_servicio (
    p_id_reserva   IN reserva.id_reserva%TYPE,
    p_id_servicio  IN servicio.id_servicio%TYPE,
    p_cantidad     IN reserva_servicio.cantidad%TYPE
  )
  IS
    v_estado          reserva.estado%TYPE;
    v_aloj_reserva    alojamiento.id_alojamiento%TYPE;
    v_aloj_servicio   alojamiento.id_alojamiento%TYPE;
    v_valor           servicio.valor%TYPE;
    v_total           NUMBER;
  BEGIN
    -- 1. La reserva debe existir y estar confirmada
    BEGIN
      SELECT estado INTO v_estado FROM reserva WHERE id_reserva = p_id_reserva;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(c_err_reserva,
          'La reserva ' || p_id_reserva || ' no existe.');
    END;

    IF v_estado <> 'CONFIRMADA' THEN
      RAISE_APPLICATION_ERROR(c_err_reserva,
        'Solo se pueden cargar servicios a una reserva CONFIRMADA. La reserva '
        || p_id_reserva || ' esta ' || v_estado || '.');
    END IF;

    -- 2. El servicio debe existir y ser del alojamiento de la reserva
    BEGIN
      SELECT valor, id_alojamiento
      INTO   v_valor, v_aloj_servicio
      FROM   servicio
      WHERE  id_servicio = p_id_servicio;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(c_err_servicio,
          'El servicio ' || p_id_servicio || ' no existe.');
    END;

    SELECT MIN(h.id_alojamiento)
    INTO   v_aloj_reserva
    FROM   reserva_habitacion rh
    JOIN   habitacion h ON h.id_habitacion = rh.id_habitacion
    WHERE  rh.id_reserva = p_id_reserva;

    IF v_aloj_reserva IS NULL OR v_aloj_servicio <> v_aloj_reserva THEN
      RAISE_APPLICATION_ERROR(c_err_servicio,
        'El servicio ' || p_id_servicio
        || ' no pertenece al alojamiento de la reserva.');
    END IF;

    IF p_cantidad IS NULL OR p_cantidad < 1 THEN
      RAISE_APPLICATION_ERROR(c_err_servicio, 'La cantidad debe ser al menos 1.');
    END IF;

    -- 3. Guardar el consumo y sumarlo al total de la reserva
    v_total := v_valor * p_cantidad;

    INSERT INTO reserva_servicio (id_reserva_servicio, id_reserva, id_servicio,
                                  cantidad, valor_total)
    VALUES (seq_reserva_servicio.NEXTVAL, p_id_reserva, p_id_servicio,
            p_cantidad, v_total);

    UPDATE reserva
    SET    valor_total = valor_total + v_total
    WHERE  id_reserva  = p_id_reserva;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Servicio cargado a la reserva ' || p_id_reserva || ' por ' || v_total);

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END sp_agregar_servicio;


  -- sp_checkout
  -- Solo para una reserva CONFIRMADA cuyo huesped ya llego. Registra un pago
  -- por lo que falte (alojamiento mas servicios menos lo ya pagado) y deja la
  -- reserva FINALIZADA, todo en la misma transaccion.
  PROCEDURE sp_checkout (
    p_id_reserva   IN reserva.id_reserva%TYPE,
    p_metodo_pago  IN pago.metodo_pago%TYPE DEFAULT 'TARJETA_CREDITO'
  )
  IS
    v_estado    reserva.estado%TYPE;
    v_entrada   reserva.fecha_checkin%TYPE;
    v_total     reserva.valor_total%TYPE;
    v_pagado    NUMBER;
  BEGIN
    BEGIN
      SELECT estado, fecha_checkin, valor_total
      INTO   v_estado, v_entrada, v_total
      FROM   reserva
      WHERE  id_reserva = p_id_reserva;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(c_err_reserva,
          'La reserva ' || p_id_reserva || ' no existe.');
    END;

    IF v_estado <> 'CONFIRMADA' THEN
      RAISE_APPLICATION_ERROR(c_err_reserva,
        'Solo se puede hacer check-out de una reserva CONFIRMADA. La reserva '
        || p_id_reserva || ' esta ' || v_estado || '.');
    END IF;

    IF v_entrada > TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(c_err_reserva,
        'El huesped de la reserva ' || p_id_reserva || ' todavia no ha llegado: su entrada es el '
        || TO_CHAR(v_entrada, 'DD/MM/YYYY') || '.');
    END IF;

    -- Cobrar lo que falte por pagar
    SELECT NVL(SUM(valor), 0)
    INTO   v_pagado
    FROM   pago
    WHERE  id_reserva = p_id_reserva;

    IF v_total > v_pagado THEN
      INSERT INTO pago (id_pago, id_reserva, fecha_pago, valor, metodo_pago)
      VALUES (seq_pago.NEXTVAL, p_id_reserva, SYSDATE, v_total - v_pagado, p_metodo_pago);
    END IF;

    UPDATE reserva
    SET    estado     = 'FINALIZADA'
    WHERE  id_reserva = p_id_reserva;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Check-out de la reserva ' || p_id_reserva || '. Cobrado: '
                         || GREATEST(v_total - v_pagado, 0));

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END sp_checkout;


  -- sp_cancelar_reserva
  -- Solo una reserva CONFIRMADA que todavia no ha empezado. Al quedar
  -- CANCELADA, la habitacion vuelve a quedar libre en esas fechas.
  PROCEDURE sp_cancelar_reserva (
    p_id_reserva   IN reserva.id_reserva%TYPE
  )
  IS
    v_estado    reserva.estado%TYPE;
    v_entrada   reserva.fecha_checkin%TYPE;
  BEGIN
    BEGIN
      SELECT estado, fecha_checkin
      INTO   v_estado, v_entrada
      FROM   reserva
      WHERE  id_reserva = p_id_reserva;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(c_err_reserva,
          'La reserva ' || p_id_reserva || ' no existe.');
    END;

    IF v_estado <> 'CONFIRMADA' THEN
      RAISE_APPLICATION_ERROR(c_err_reserva,
        'Solo se puede cancelar una reserva CONFIRMADA. La reserva '
        || p_id_reserva || ' esta ' || v_estado || '.');
    END IF;

    IF v_entrada <= TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(c_err_reserva,
        'La estadia de la reserva ' || p_id_reserva || ' ya empezo el '
        || TO_CHAR(v_entrada, 'DD/MM/YYYY') || ', no se puede cancelar.');
    END IF;

    UPDATE reserva
    SET    estado     = 'CANCELADA'
    WHERE  id_reserva = p_id_reserva;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Reserva ' || p_id_reserva || ' cancelada.');

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END sp_cancelar_reserva;


  -- sp_actualizar_tarifa
  -- Una vez empieza una temporada su precio ya no cambia: las reservas de esa
  -- temporada se cotizaron con ese valor. El cambio queda registrado por el
  -- disparador de auditoria.
  PROCEDURE sp_actualizar_tarifa (
    p_id_tarifa    IN tarifa.id_tarifa%TYPE,
    p_valor_noche  IN tarifa.valor_noche%TYPE
  )
  IS
    v_inicio  temporada.fecha_inicio%TYPE;
    v_nombre  temporada.nombre%TYPE;
  BEGIN
    IF p_valor_noche IS NULL OR p_valor_noche <= 0 THEN
      RAISE_APPLICATION_ERROR(c_err_dato_invalido,
        'La tarifa por noche debe ser mayor que cero.');
    END IF;

    BEGIN
      SELECT t.fecha_inicio, t.nombre
      INTO   v_inicio, v_nombre
      FROM   tarifa tf
      JOIN   temporada t ON t.id_temporada = tf.id_temporada
      WHERE  tf.id_tarifa = p_id_tarifa;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(c_err_dato_invalido,
          'La tarifa ' || p_id_tarifa || ' no existe.');
    END;

    IF v_inicio <= TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(c_err_temporada_iniciada,
        'La temporada ' || v_nombre || ' ya empezo, su tarifa no se puede modificar.');
    END IF;

    UPDATE tarifa
    SET    valor_noche = p_valor_noche
    WHERE  id_tarifa   = p_id_tarifa;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Tarifa ' || p_id_tarifa || ' actualizada a ' || p_valor_noche);

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END sp_actualizar_tarifa;


  -- sp_ajustar_tarifas
  -- Un solo UPDATE para todas las tarifas: el disparador de auditoria lo
  -- registra como una sentencia, con una fila por cada tarifa cambiada.
  -- El nuevo valor se redondea a centenas.
  PROCEDURE sp_ajustar_tarifas (
    p_id_alojamiento  IN  alojamiento.id_alojamiento%TYPE,
    p_anio            IN  NUMBER,
    p_porcentaje      IN  NUMBER,
    p_afectadas       OUT NUMBER
  )
  IS
  BEGIN
    IF p_porcentaje IS NULL OR p_porcentaje = 0
       OR p_porcentaje < -50 OR p_porcentaje > 100 THEN
      RAISE_APPLICATION_ERROR(c_err_dato_invalido,
        'El ajuste debe estar entre -50% y +100%, y ser distinto de cero.');
    END IF;

    UPDATE tarifa
    SET    valor_noche = ROUND(valor_noche * (1 + p_porcentaje / 100), -2)
    WHERE  id_habitacion IN (SELECT id_habitacion FROM habitacion
                             WHERE  id_alojamiento = p_id_alojamiento)
      AND  id_temporada  IN (SELECT id_temporada FROM temporada
                             WHERE  EXTRACT(YEAR FROM fecha_inicio) = p_anio
                               AND  fecha_inicio > TRUNC(SYSDATE));

    p_afectadas := SQL%ROWCOUNT;

    IF p_afectadas = 0 THEN
      RAISE_APPLICATION_ERROR(c_err_temporada_iniciada,
        'El alojamiento ' || p_id_alojamiento || ' no tiene tarifas de temporadas de '
        || p_anio || ' que todavia no hayan empezado.');
    END IF;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE(p_afectadas || ' tarifas ajustadas en ' || p_porcentaje || '%.');

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END sp_ajustar_tarifas;


  -- sp_cambiar_estado_habitacion
  -- Una habitacion en MANTENIMIENTO o INACTIVA no se puede reservar
  -- (sp_crear_reserva lo valida).
  PROCEDURE sp_cambiar_estado_habitacion (
    p_id_habitacion  IN habitacion.id_habitacion%TYPE,
    p_estado         IN habitacion.estado%TYPE
  )
  IS
  BEGIN
    IF p_estado IS NULL OR p_estado NOT IN ('DISPONIBLE', 'MANTENIMIENTO', 'INACTIVA') THEN
      RAISE_APPLICATION_ERROR(c_err_dato_invalido,
        'El estado de una habitacion solo puede ser DISPONIBLE, MANTENIMIENTO o INACTIVA.');
    END IF;

    UPDATE habitacion
    SET    estado        = p_estado
    WHERE  id_habitacion = p_id_habitacion;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(c_err_habitacion,
        'La habitacion ' || p_id_habitacion || ' no existe.');
    END IF;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Habitacion ' || p_id_habitacion || ' en estado ' || p_estado);

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END sp_cambiar_estado_habitacion;


  -- sp_reabrir_liquidacion
  -- Deja el mes sin liquidar para que se pueda volver a procesar.
  PROCEDURE sp_reabrir_liquidacion (
    p_periodo  IN DATE
  )
  IS
    v_desde  DATE := TRUNC(p_periodo, 'MM');
  BEGIN
    DELETE FROM liquidacion_mensual
    WHERE  periodo = v_desde;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(c_err_liquidacion,
        'El mes ' || TO_CHAR(v_desde, 'MM/YYYY') || ' no esta liquidado.');
    END IF;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Mes ' || TO_CHAR(v_desde, 'MM/YYYY') || ' reabierto.');

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END sp_reabrir_liquidacion;

END pkg_turismouq;
/
SHOW ERRORS PACKAGE BODY pkg_turismouq

SET LINESIZE 100;
SET PAGESIZE 50;
SET TAB OFF;
COLUMN object_name FORMAT A16
COLUMN object_type FORMAT A14
COLUMN status      FORMAT A8

PROMPT Estado del paquete:
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name = 'PKG_TURISMOUQ'
ORDER  BY object_type;
