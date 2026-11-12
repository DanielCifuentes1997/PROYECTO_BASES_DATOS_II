"""
TurismoUQ - Servidor de la interfaz web.

Regla de esta capa: el servidor solo LEE datos con SELECT para mostrarlos.
Todo lo que crea, modifica o borra datos lo hace el paquete PKG_TURISMOUQ
dentro de Oracle, que es donde estan las validaciones y las reglas del negocio.
Si una regla se incumple, el paquete lanza un error propio (ORA-20xxx) y aqui
solo se toma su mensaje para mostrarlo en pantalla.
"""
import os
import re
from datetime import datetime, date
from typing import Optional

import oracledb
from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

app = FastAPI(
    title="TurismoUQ · Plataforma de Alojamientos y Reservas del Quindío",
    version="5.0.0",
)

# Solo la propia interfaz puede llamar a la API (no cualquier pagina web
# abierta en el navegador).
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:8050", "http://localhost:8050"],
    allow_methods=["*"],
    allow_headers=["*"],
)

DB_USER = "turismouq"
DB_PASS = "Daniel.sharond15"
DB_DSN = "localhost:1521/XEPDB1"

pool: Optional[oracledb.ConnectionPool] = None


def get_pool() -> oracledb.ConnectionPool:
    global pool
    if pool is None:
        pool = oracledb.create_pool(user=DB_USER, password=DB_PASS, dsn=DB_DSN,
                                    min=1, max=8, increment=1)
    return pool


def mensaje_oracle(err: Exception) -> str:
    """Deja solo el texto del error que lanzo el paquete (ORA-20xxx)."""
    msg = str(err)
    propio = re.search(r"ORA-20\d{3}:\s*([^\n]+)", msg)
    if propio:
        return propio.group(1).strip()
    otro = re.search(r"ORA-\d{5}:\s*([^\n]+)", msg)
    if otro:
        return otro.group(1).strip()
    return msg.split("\n")[0]


def filas(cursor) -> list[dict]:
    columnas = [d[0].lower() for d in cursor.description]
    resultado = []
    for fila in cursor.fetchall():
        item = {}
        for k, v in zip(columnas, fila):
            item[k] = v.strftime("%Y-%m-%d") if isinstance(v, (datetime, date)) else v
        resultado.append(item)
    return resultado


def consultar(sql: str, params: Optional[dict] = None) -> list[dict]:
    with get_pool().acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params or {})
            return filas(cur)


def ejecutar_paquete(bloque: str, params: dict) -> dict:
    """Ejecuta un bloque que llama al paquete. El COMMIT/ROLLBACK lo hace el paquete."""
    with get_pool().acquire() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute(bloque, params)
                return {"ok": True}
            except Exception as e:
                return {"ok": False, "mensaje": mensaje_oracle(e)}


# =====================================================================
# Datos que envia la pagina
# =====================================================================
class CotizarRequest(BaseModel):
    id_habitacion: int
    fecha_in: str
    fecha_out: str


class CrearReservaRequest(BaseModel):
    id_cliente: int
    id_habitacion: int
    fecha_in: str
    fecha_out: str
    num_huespedes: int


class NuevoClienteRequest(BaseModel):
    nombre: str
    documento: str
    email: str


class ServicioRequest(BaseModel):
    id_servicio: int
    cantidad: int = 1


class CheckoutRequest(BaseModel):
    metodo_pago: str = "TARJETA_CREDITO"


class EstadoHabitacionRequest(BaseModel):
    estado: str


class TarifaRequest(BaseModel):
    valor_noche: float


class AjusteTarifasRequest(BaseModel):
    id_alojamiento: int
    anio: int
    porcentaje: float


class LiquidarRequest(BaseModel):
    periodo: str
    porcentaje: float = 12.0


class ReabrirRequest(BaseModel):
    periodo: str


# =====================================================================
# 1. Catalogo: municipios, tipos y alojamientos
# =====================================================================
@app.get("/api/init")
def datos_iniciales():
    municipios = consultar("""
        SELECT m.id_municipio, m.nombre, COUNT(a.id_alojamiento) AS total_alojamientos
        FROM   municipio m
        LEFT   JOIN alojamiento a ON a.id_municipio = m.id_municipio
        GROUP  BY m.id_municipio, m.nombre
        ORDER  BY m.nombre
    """)
    tipos = consultar("SELECT id_tipo, nombre FROM tipo_alojamiento ORDER BY nombre")

    # Habitaciones y precios se calculan por separado para no multiplicar
    # filas: cada habitacion tiene 28 tarifas, una por temporada.
    alojamientos = consultar("""
        SELECT a.id_alojamiento, a.nombre, a.id_municipio, m.nombre AS municipio,
               a.id_tipo, ta.nombre AS tipo, a.capacidad_max,
               (SELECT COUNT(*) FROM habitacion h
                WHERE  h.id_alojamiento = a.id_alojamiento) AS total_habitaciones,
               (SELECT COUNT(*) FROM habitacion h
                WHERE  h.id_alojamiento = a.id_alojamiento
                  AND  h.estado = 'DISPONIBLE') AS habitaciones_disponibles,
               (SELECT MIN(tf.valor_noche)
                FROM   tarifa tf
                JOIN   habitacion h ON h.id_habitacion = tf.id_habitacion
                JOIN   temporada t  ON t.id_temporada  = tf.id_temporada
                WHERE  h.id_alojamiento = a.id_alojamiento
                  AND  t.fecha_fin >= TRUNC(SYSDATE)) AS precio_desde,
               (SELECT ROUND(AVG(x.calificacion), 1)
                FROM  (SELECT DISTINCT rs.id_resena, rs.calificacion
                       FROM   resena rs
                       JOIN   reserva_habitacion rh ON rh.id_reserva = rs.id_reserva
                       JOIN   habitacion h ON h.id_habitacion = rh.id_habitacion
                       WHERE  h.id_alojamiento = a.id_alojamiento) x) AS calificacion,
               (SELECT COUNT(DISTINCT rs.id_resena)
                FROM   resena rs
                JOIN   reserva_habitacion rh ON rh.id_reserva = rs.id_reserva
                JOIN   habitacion h ON h.id_habitacion = rh.id_habitacion
                WHERE  h.id_alojamiento = a.id_alojamiento) AS total_resenas
        FROM   alojamiento a
        JOIN   municipio m         ON m.id_municipio = a.id_municipio
        JOIN   tipo_alojamiento ta ON ta.id_tipo     = a.id_tipo
        ORDER  BY m.nombre, a.nombre
    """)
    return {"municipios": municipios, "tipos": tipos, "alojamientos": alojamientos}


@app.get("/api/alojamientos/{id_alojamiento}")
def detalle_alojamiento(id_alojamiento: int):
    habitaciones = consultar("""
        SELECT h.id_habitacion, h.numero, h.tipo_habitacion, h.estado, h.capacidad,
               (SELECT MIN(tf.valor_noche) FROM tarifa tf
                WHERE  tf.id_habitacion = h.id_habitacion) AS tarifa_baja,
               (SELECT MAX(tf.valor_noche) FROM tarifa tf
                WHERE  tf.id_habitacion = h.id_habitacion) AS tarifa_alta,
               (SELECT COUNT(*)
                FROM   reserva_habitacion rh
                JOIN   reserva r ON r.id_reserva = rh.id_reserva
                WHERE  rh.id_habitacion = h.id_habitacion
                  AND  r.estado = 'CONFIRMADA'
                  AND  r.fecha_checkin <= TRUNC(SYSDATE)
                  AND  r.fecha_checkout > TRUNC(SYSDATE)) AS ocupada_hoy
        FROM   habitacion h
        WHERE  h.id_alojamiento = :id
        ORDER  BY h.numero
    """, {"id": id_alojamiento})

    servicios = consultar("""
        SELECT id_servicio, nombre, valor
        FROM   servicio
        WHERE  id_alojamiento = :id
        ORDER  BY nombre
    """, {"id": id_alojamiento})

    tarifas = consultar("""
        SELECT tf.id_tarifa, tf.id_habitacion, h.numero AS hab_numero, h.tipo_habitacion,
               t.nombre AS temporada, t.tipo AS tipo_temporada,
               TO_CHAR(t.fecha_inicio, 'YYYY-MM-DD') AS fecha_inicio,
               TO_CHAR(t.fecha_fin, 'YYYY-MM-DD') AS fecha_fin,
               EXTRACT(YEAR FROM t.fecha_inicio) AS anio,
               tf.valor_noche,
               CASE WHEN t.fecha_inicio > TRUNC(SYSDATE) THEN 1 ELSE 0 END AS editable
        FROM   tarifa tf
        JOIN   habitacion h ON h.id_habitacion = tf.id_habitacion
        JOIN   temporada t  ON t.id_temporada  = tf.id_temporada
        WHERE  h.id_alojamiento = :id
          AND  t.fecha_fin >= TRUNC(SYSDATE, 'YYYY')
        ORDER  BY h.numero, t.fecha_inicio
    """, {"id": id_alojamiento})

    return {"habitaciones": habitaciones, "servicios": servicios, "tarifas": tarifas}


# =====================================================================
# 2. Clientes, cotizacion y reservas
# =====================================================================
@app.get("/api/clientes/buscar")
def buscar_cliente(documento: str = Query(...)):
    encontrados = consultar("""
        SELECT id_cliente, nombre, documento, email
        FROM   cliente
        WHERE  documento = :doc
    """, {"doc": documento.strip()})
    return {"encontrado": bool(encontrados), "cliente": encontrados[0] if encontrados else None}


@app.post("/api/clientes/crear")
def registrar_cliente(req: NuevoClienteRequest):
    with get_pool().acquire() as conn:
        with conn.cursor() as cur:
            try:
                id_cliente = cur.var(int)
                cur.execute("""
                    BEGIN
                      pkg_turismouq.sp_registrar_cliente(
                        p_nombre     => :nom,
                        p_documento  => :doc,
                        p_email      => :em,
                        p_id_cliente => :id);
                    END;
                """, {"nom": req.nombre, "doc": req.documento, "em": req.email, "id": id_cliente})
                return {"ok": True, "cliente": {"id_cliente": id_cliente.getvalue(),
                                                "nombre": req.nombre.strip(),
                                                "documento": req.documento.strip(),
                                                "email": req.email.strip().lower()}}
            except Exception as e:
                return {"ok": False, "mensaje": mensaje_oracle(e)}


@app.post("/api/reservas/cotizar")
def cotizar_estadia(req: CotizarRequest):
    params = {"hab": req.id_habitacion, "fin": req.fecha_in, "fout": req.fecha_out}
    with get_pool().acquire() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute("""
                    SELECT pkg_turismouq.fn_valor_estadia(
                             :hab, TO_DATE(:fin, 'YYYY-MM-DD'), TO_DATE(:fout, 'YYYY-MM-DD'))
                    FROM dual
                """, params)
                valor_total = cur.fetchone()[0]

                libre = cur.var(int)
                cur.execute("""
                    BEGIN
                      IF pkg_turismouq.fn_habitacion_disponible(
                           :hab, TO_DATE(:fin, 'YYYY-MM-DD'), TO_DATE(:fout, 'YYYY-MM-DD')) THEN
                        :libre := 1;
                      ELSE
                        :libre := 0;
                      END IF;
                    END;
                """, {**params, "libre": libre})

                cur.execute("""
                    SELECT t.nombre AS temporada, t.tipo AS tipo_temporada,
                           tf.valor_noche AS tarifa_noche,
                           LEAST(TO_DATE(:fout, 'YYYY-MM-DD') - 1, t.fecha_fin)
                             - GREATEST(TO_DATE(:fin, 'YYYY-MM-DD'), t.fecha_inicio) + 1 AS noches
                    FROM   temporada t
                    JOIN   tarifa tf ON tf.id_temporada  = t.id_temporada
                                    AND tf.id_habitacion = :hab
                    WHERE  t.fecha_inicio <= TO_DATE(:fout, 'YYYY-MM-DD') - 1
                      AND  t.fecha_fin    >= TO_DATE(:fin, 'YYYY-MM-DD')
                    ORDER  BY t.fecha_inicio
                """, params)
                tramos = filas(cur)
                for t in tramos:
                    t["subtotal"] = t["noches"] * t["tarifa_noche"]

                return {"ok": True, "valor_total": float(valor_total),
                        "disponible": bool(libre.getvalue()),
                        "noches_totales": sum(t["noches"] for t in tramos),
                        "tramos": tramos}
            except Exception as e:
                return {"ok": False, "mensaje": mensaje_oracle(e)}


@app.post("/api/reservas/crear")
def crear_reserva(req: CrearReservaRequest):
    with get_pool().acquire() as conn:
        with conn.cursor() as cur:
            try:
                id_reserva = cur.var(int)
                cur.execute("""
                    BEGIN
                      pkg_turismouq.sp_crear_reserva(
                        p_id_cliente    => :cli,
                        p_id_habitacion => :hab,
                        p_fecha_in      => TO_DATE(:fin, 'YYYY-MM-DD'),
                        p_fecha_out     => TO_DATE(:fout, 'YYYY-MM-DD'),
                        p_num_huespedes => :hues,
                        p_id_reserva    => :id);
                    END;
                """, {"cli": req.id_cliente, "hab": req.id_habitacion, "fin": req.fecha_in,
                      "fout": req.fecha_out, "hues": req.num_huespedes, "id": id_reserva})
                nuevo = id_reserva.getvalue()
            except Exception as e:
                return {"ok": False, "mensaje": mensaje_oracle(e)}

    reserva = consultar("""
        SELECT r.id_reserva, c.nombre AS cliente, c.documento,
               TO_CHAR(r.fecha_checkin, 'YYYY-MM-DD') AS fecha_checkin,
               TO_CHAR(r.fecha_checkout, 'YYYY-MM-DD') AS fecha_checkout,
               r.num_huespedes, r.estado, r.valor_total,
               h.numero AS hab_numero, a.nombre AS alojamiento, m.nombre AS municipio
        FROM   reserva r
        JOIN   cliente c ON c.id_cliente = r.id_cliente
        JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
        JOIN   habitacion h  ON h.id_habitacion  = rh.id_habitacion
        JOIN   alojamiento a ON a.id_alojamiento = h.id_alojamiento
        JOIN   municipio m   ON m.id_municipio   = a.id_municipio
        WHERE  r.id_reserva = :id
        FETCH FIRST 1 ROWS ONLY
    """, {"id": nuevo})[0]
    return {"ok": True, "id_reserva": nuevo, "reserva": reserva}


# =====================================================================
# 3. Recepcion
# =====================================================================
# Que reservas muestra cada pestana de recepcion
VISTAS_RECEPCION = {
    "llegadas": ("r.estado = 'CONFIRMADA' AND r.fecha_checkin = TRUNC(SYSDATE)",
                 "r.id_reserva"),
    "alojados": ("r.estado = 'CONFIRMADA' AND r.fecha_checkin <= TRUNC(SYSDATE) "
                 "AND r.fecha_checkout > TRUNC(SYSDATE)",
                 "r.fecha_checkout, r.id_reserva"),
    "salidas":  ("r.estado = 'CONFIRMADA' AND r.fecha_checkout <= TRUNC(SYSDATE)",
                 "r.fecha_checkout DESC, r.id_reserva"),
    "proximas": ("r.estado = 'CONFIRMADA' AND r.fecha_checkin > TRUNC(SYSDATE) "
                 "AND r.fecha_checkin <= TRUNC(SYSDATE) + 7",
                 "r.fecha_checkin, r.id_reserva"),
    "todas":    ("1 = 1", "r.fecha_checkin DESC, r.id_reserva DESC"),
}


@app.get("/api/recepcion/resumen")
def resumen_recepcion(id_alojamiento: Optional[int] = Query(None)):
    filtro = ("AND EXISTS (SELECT 1 FROM reserva_habitacion rh "
              "JOIN habitacion h ON h.id_habitacion = rh.id_habitacion "
              "WHERE rh.id_reserva = r.id_reserva AND h.id_alojamiento = :aloj)"
              if id_alojamiento else "")
    params = {"aloj": id_alojamiento} if id_alojamiento else {}
    resumen = {}
    for vista, (condicion, _) in VISTAS_RECEPCION.items():
        if vista == "todas":
            continue
        resumen[vista] = consultar(
            f"SELECT COUNT(*) AS n FROM reserva r WHERE {condicion} {filtro}", params)[0]["n"]
    return resumen


@app.get("/api/recepcion/reservas")
def reservas_recepcion(vista: str = Query("llegadas"),
                       id_alojamiento: Optional[int] = Query(None),
                       busqueda: Optional[str] = Query(None)):
    condicion, orden = VISTAS_RECEPCION.get(vista, VISTAS_RECEPCION["llegadas"])
    condiciones = [condicion]
    params = {}
    if id_alojamiento:
        condiciones.append("a.id_alojamiento = :aloj")
        params["aloj"] = id_alojamiento
    if busqueda and busqueda.strip():
        condiciones.append("(UPPER(c.nombre) LIKE UPPER(:q) OR c.documento LIKE :q "
                           "OR TO_CHAR(r.id_reserva) = :qexacta)")
        params["q"] = f"%{busqueda.strip()}%"
        params["qexacta"] = busqueda.strip()

    reservas = consultar(f"""
        SELECT r.id_reserva, c.nombre AS cliente, c.documento,
               TO_CHAR(r.fecha_checkin, 'YYYY-MM-DD') AS fecha_checkin,
               TO_CHAR(r.fecha_checkout, 'YYYY-MM-DD') AS fecha_checkout,
               r.fecha_checkout - r.fecha_checkin AS noches,
               r.num_huespedes, r.estado, r.valor_total,
               LISTAGG(DISTINCT h.numero, ', ') WITHIN GROUP (ORDER BY h.numero) AS habitaciones,
               MIN(a.nombre) AS alojamiento, MIN(m.nombre) AS municipio,
               CASE WHEN r.estado = 'CONFIRMADA' AND r.fecha_checkin <= TRUNC(SYSDATE)
                    THEN 1 ELSE 0 END AS puede_checkout,
               CASE WHEN r.estado = 'CONFIRMADA' AND r.fecha_checkin > TRUNC(SYSDATE)
                    THEN 1 ELSE 0 END AS puede_cancelar
        FROM   reserva r
        JOIN   cliente c             ON c.id_cliente     = r.id_cliente
        JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
        JOIN   habitacion h          ON h.id_habitacion  = rh.id_habitacion
        JOIN   alojamiento a         ON a.id_alojamiento = h.id_alojamiento
        JOIN   municipio m           ON m.id_municipio   = a.id_municipio
        WHERE  {" AND ".join(condiciones)}
        GROUP  BY r.id_reserva, c.nombre, c.documento, r.fecha_checkin, r.fecha_checkout,
                  r.num_huespedes, r.estado, r.valor_total
        ORDER  BY {orden}
        FETCH FIRST 50 ROWS ONLY
    """, params)
    return {"reservas": reservas}


@app.get("/api/recepcion/reservas/{id_reserva}")
def cuenta_reserva(id_reserva: int):
    cabecera = consultar("""
        SELECT r.id_reserva, c.nombre AS cliente, c.documento, r.estado,
               TO_CHAR(r.fecha_checkin, 'YYYY-MM-DD') AS fecha_checkin,
               TO_CHAR(r.fecha_checkout, 'YYYY-MM-DD') AS fecha_checkout,
               r.num_huespedes, r.valor_total,
               (SELECT NVL(SUM(p.valor), 0) FROM pago p
                WHERE  p.id_reserva = r.id_reserva) AS pagado,
               CASE WHEN r.estado = 'CONFIRMADA' AND r.fecha_checkin <= TRUNC(SYSDATE)
                    THEN 1 ELSE 0 END AS puede_checkout,
               CASE WHEN r.estado = 'CONFIRMADA' AND r.fecha_checkin > TRUNC(SYSDATE)
                    THEN 1 ELSE 0 END AS puede_cancelar
        FROM   reserva r
        JOIN   cliente c ON c.id_cliente = r.id_cliente
        WHERE  r.id_reserva = :id
    """, {"id": id_reserva})
    if not cabecera:
        return {"ok": False, "mensaje": f"La reserva {id_reserva} no existe."}

    estadia = consultar("""
        SELECT h.numero AS hab_numero, t.nombre AS temporada, t.tipo AS tipo_temporada,
               rh.noches, rh.valor_noche_aplicado, rh.noches * rh.valor_noche_aplicado AS subtotal
        FROM   reserva_habitacion rh
        JOIN   habitacion h ON h.id_habitacion = rh.id_habitacion
        JOIN   temporada t  ON t.id_temporada  = rh.id_temporada
        WHERE  rh.id_reserva = :id
        ORDER  BY h.numero, t.fecha_inicio
    """, {"id": id_reserva})

    consumos = consultar("""
        SELECT s.nombre AS servicio, rs.cantidad, s.valor AS valor_unitario, rs.valor_total
        FROM   reserva_servicio rs
        JOIN   servicio s ON s.id_servicio = rs.id_servicio
        WHERE  rs.id_reserva = :id
        ORDER  BY rs.id_reserva_servicio
    """, {"id": id_reserva})

    servicios = consultar("""
        SELECT s.id_servicio, s.nombre, s.valor
        FROM   servicio s
        WHERE  s.id_alojamiento = (SELECT MIN(h.id_alojamiento)
                                   FROM   reserva_habitacion rh
                                   JOIN   habitacion h ON h.id_habitacion = rh.id_habitacion
                                   WHERE  rh.id_reserva = :id)
        ORDER  BY s.nombre
    """, {"id": id_reserva})

    return {"ok": True, "reserva": cabecera[0], "estadia": estadia,
            "consumos": consumos, "servicios_disponibles": servicios}


@app.post("/api/recepcion/reservas/{id_reserva}/servicios")
def agregar_servicio(id_reserva: int, req: ServicioRequest):
    return ejecutar_paquete("""
        BEGIN
          pkg_turismouq.sp_agregar_servicio(
            p_id_reserva => :res, p_id_servicio => :srv, p_cantidad => :cant);
        END;
    """, {"res": id_reserva, "srv": req.id_servicio, "cant": req.cantidad})


@app.post("/api/recepcion/reservas/{id_reserva}/checkout")
def checkout(id_reserva: int, req: CheckoutRequest):
    return ejecutar_paquete("""
        BEGIN
          pkg_turismouq.sp_checkout(p_id_reserva => :res, p_metodo_pago => :met);
        END;
    """, {"res": id_reserva, "met": req.metodo_pago})


@app.post("/api/recepcion/reservas/{id_reserva}/cancelar")
def cancelar(id_reserva: int):
    return ejecutar_paquete("""
        BEGIN
          pkg_turismouq.sp_cancelar_reserva(p_id_reserva => :res);
        END;
    """, {"res": id_reserva})


# =====================================================================
# 4. Administrador de alojamiento
# =====================================================================
@app.post("/api/admin/habitaciones/{id_habitacion}/estado")
def cambiar_estado_habitacion(id_habitacion: int, req: EstadoHabitacionRequest):
    return ejecutar_paquete("""
        BEGIN
          pkg_turismouq.sp_cambiar_estado_habitacion(p_id_habitacion => :hab, p_estado => :est);
        END;
    """, {"hab": id_habitacion, "est": req.estado})


@app.post("/api/admin/tarifas/{id_tarifa}")
def actualizar_tarifa(id_tarifa: int, req: TarifaRequest):
    return ejecutar_paquete("""
        BEGIN
          pkg_turismouq.sp_actualizar_tarifa(p_id_tarifa => :id, p_valor_noche => :val);
        END;
    """, {"id": id_tarifa, "val": req.valor_noche})


@app.post("/api/admin/tarifas-ajuste")
def ajustar_tarifas(req: AjusteTarifasRequest):
    with get_pool().acquire() as conn:
        with conn.cursor() as cur:
            try:
                afectadas = cur.var(int)
                cur.execute("""
                    BEGIN
                      pkg_turismouq.sp_ajustar_tarifas(
                        p_id_alojamiento => :aloj, p_anio => :anio,
                        p_porcentaje => :pct, p_afectadas => :afec);
                    END;
                """, {"aloj": req.id_alojamiento, "anio": req.anio,
                      "pct": req.porcentaje, "afec": afectadas})
                return {"ok": True, "afectadas": afectadas.getvalue()}
            except Exception as e:
                return {"ok": False, "mensaje": mensaje_oracle(e)}


# =====================================================================
# 5. Gerencia
# =====================================================================
@app.get("/api/gerencia/resumen")
def resumen_gerencia(anio: int = Query(2025)):
    kpis = consultar("""
        SELECT COUNT(DISTINCT r.id_reserva) AS reservas,
               SUM(rh.noches) AS noches,
               ROUND(SUM(rh.noches * rh.valor_noche_aplicado) / 1000000, 1) AS ingresos_aloj_mill
        FROM   reserva r
        JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
        WHERE  r.estado <> 'CANCELADA'
          AND  EXTRACT(YEAR FROM r.fecha_checkin) = :anio
    """, {"anio": anio})[0]
    kpis.update(consultar("""
        SELECT ROUND(SUM(rs.valor_total) / 1000000, 1) AS ingresos_serv_mill
        FROM   reserva_servicio rs
        JOIN   reserva r ON r.id_reserva = rs.id_reserva
        WHERE  r.estado <> 'CANCELADA'
          AND  EXTRACT(YEAR FROM r.fecha_checkin) = :anio
    """, {"anio": anio})[0])
    kpis.update(consultar("""
        SELECT ROUND(AVG(rs.calificacion), 2) AS calificacion
        FROM   resena rs
        JOIN   reserva r ON r.id_reserva = rs.id_reserva
        WHERE  EXTRACT(YEAR FROM r.fecha_checkin) = :anio
    """, {"anio": anio})[0])

    # Consulta 1 de la Entrega 1: ocupacion por municipio y mes con PIVOT
    ocupacion = consultar("""
        WITH inventario AS (
          SELECT m.nombre AS municipio, COUNT(*) AS habitaciones
          FROM   habitacion h
          JOIN   alojamiento a ON a.id_alojamiento = h.id_alojamiento
          JOIN   municipio m   ON m.id_municipio   = a.id_municipio
          GROUP  BY m.nombre
        ),
        vendido AS (
          SELECT m.nombre AS municipio, TO_CHAR(r.fecha_checkin, 'MM') AS mes,
                 SUM(rh.noches) AS noches,
                 MAX(TO_NUMBER(TO_CHAR(LAST_DAY(r.fecha_checkin), 'DD'))) AS dias_mes
          FROM   reserva r
          JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
          JOIN   habitacion h          ON h.id_habitacion  = rh.id_habitacion
          JOIN   alojamiento a         ON a.id_alojamiento = h.id_alojamiento
          JOIN   municipio m           ON m.id_municipio   = a.id_municipio
          WHERE  r.estado <> 'CANCELADA'
            AND  EXTRACT(YEAR FROM r.fecha_checkin) = :anio
          GROUP  BY m.nombre, TO_CHAR(r.fecha_checkin, 'MM')
        )
        SELECT *
        FROM  (SELECT v.municipio, v.mes,
                      ROUND(v.noches * 100 / (i.habitaciones * v.dias_mes), 1) AS pct
               FROM   vendido v JOIN inventario i ON i.municipio = v.municipio)
        PIVOT (MAX(pct) FOR mes IN ('01' AS ENE, '02' AS FEB, '03' AS MAR, '04' AS ABR,
                                    '05' AS MAY, '06' AS JUN, '07' AS JUL, '08' AS AGO,
                                    '09' AS SEP, '10' AS OCT, '11' AS NOV, '12' AS DIC))
        ORDER BY municipio
    """, {"anio": anio})

    # Consulta 4 de la Entrega 1: variacion mes contra mes con LAG
    # (solo hasta el mes actual, sin reservas futuras)
    evolucion = consultar("""
        WITH ingresos_mes AS (
          SELECT TRUNC(r.fecha_checkin, 'MM') AS mes,
                 SUM(rh.noches * rh.valor_noche_aplicado) AS ingresos
          FROM   reserva r
          JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
          WHERE  r.estado <> 'CANCELADA'
            AND  r.fecha_checkin < ADD_MONTHS(TRUNC(SYSDATE, 'MM'), 1)
          GROUP  BY TRUNC(r.fecha_checkin, 'MM')
        )
        SELECT TO_CHAR(mes, 'YYYY-MM') AS mes,
               ROUND(ingresos / 1000000, 1) AS ingresos_millones,
               ROUND((ingresos - LAG(ingresos) OVER (ORDER BY mes)) * 100
                     / LAG(ingresos) OVER (ORDER BY mes), 1) AS variacion_pct
        FROM   ingresos_mes
        ORDER  BY mes
    """)

    # Consulta 3 de la Entrega 1: top 3 por municipio con RANK y PARTITION BY
    ranking = consultar("""
        SELECT municipio, puesto, alojamiento, tipo, reservas, ingresos_millones
        FROM (
          SELECT m.nombre AS municipio, a.nombre AS alojamiento, ta.nombre AS tipo,
                 COUNT(DISTINCT r.id_reserva) AS reservas,
                 ROUND(SUM(rh.noches * rh.valor_noche_aplicado) / 1000000, 1) AS ingresos_millones,
                 RANK() OVER (PARTITION BY m.nombre
                              ORDER BY SUM(rh.noches * rh.valor_noche_aplicado) DESC) AS puesto
          FROM   reserva r
          JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
          JOIN   habitacion h          ON h.id_habitacion  = rh.id_habitacion
          JOIN   alojamiento a         ON a.id_alojamiento = h.id_alojamiento
          JOIN   tipo_alojamiento ta   ON ta.id_tipo       = a.id_tipo
          JOIN   municipio m           ON m.id_municipio   = a.id_municipio
          WHERE  r.estado <> 'CANCELADA'
            AND  EXTRACT(YEAR FROM r.fecha_checkin) = :anio
          GROUP  BY m.nombre, a.nombre, ta.nombre
        )
        WHERE puesto <= 3
        ORDER BY municipio, puesto
    """, {"anio": anio})

    # Consulta 8 de la Entrega 1: bien calificados pero con pocas ventas
    promocion = consultar("""
        SELECT alojamiento, municipio, tipo, calificacion, resenas,
               puesto_calidad, puesto_ventas, puesto_ventas - puesto_calidad AS brecha
        FROM (
          SELECT a.nombre AS alojamiento, m.nombre AS municipio, ta.nombre AS tipo,
                 ROUND(AVG(rs.calificacion), 2) AS calificacion,
                 COUNT(DISTINCT rs.id_resena) AS resenas,
                 RANK() OVER (ORDER BY AVG(rs.calificacion) DESC) AS puesto_calidad,
                 RANK() OVER (ORDER BY SUM(rh.noches) DESC) AS puesto_ventas
          FROM   resena rs
          JOIN   reserva r             ON r.id_reserva     = rs.id_reserva
          JOIN   reserva_habitacion rh ON rh.id_reserva    = r.id_reserva
          JOIN   habitacion h          ON h.id_habitacion  = rh.id_habitacion
          JOIN   alojamiento a         ON a.id_alojamiento = h.id_alojamiento
          JOIN   tipo_alojamiento ta   ON ta.id_tipo       = a.id_tipo
          JOIN   municipio m           ON m.id_municipio   = a.id_municipio
          GROUP  BY a.nombre, m.nombre, ta.nombre
          HAVING COUNT(DISTINCT rs.id_resena) >= 25
        )
        ORDER BY brecha DESC
        FETCH FIRST 10 ROWS ONLY
    """)

    return {"anio": anio, "kpis": kpis, "ocupacion": ocupacion, "evolucion": evolucion,
            "ranking": ranking, "promocion": promocion}


@app.get("/api/gerencia/liquidaciones")
def liquidaciones(periodo: Optional[str] = Query(None)):
    # Meses que se pueden liquidar: ya terminados y con estadias finalizadas
    periodos = consultar("""
        SELECT DISTINCT TO_CHAR(TRUNC(fecha_checkout, 'MM'), 'YYYY-MM-DD') AS periodo
        FROM   reserva
        WHERE  estado = 'FINALIZADA'
          AND  fecha_checkout < TRUNC(SYSDATE, 'MM')
        ORDER  BY periodo DESC
        FETCH FIRST 24 ROWS ONLY
    """)
    periodo = periodo or (periodos[0]["periodo"] if periodos else None)

    liquidados = consultar("""
        SELECT TO_CHAR(periodo, 'YYYY-MM-DD') AS periodo,
               COUNT(*) AS alojamientos,
               MAX(porcentaje_comision) AS porcentaje_comision,
               SUM(valor_comision) AS total_comision,
               SUM(valor_a_pagar) AS total_pagar
        FROM   liquidacion_mensual
        GROUP  BY periodo
        ORDER  BY periodo DESC
    """)

    detalle = consultar("""
        SELECT l.id_alojamiento, a.nombre AS alojamiento, m.nombre AS municipio, l.reservas,
               l.ingreso_alojamiento, l.ingreso_servicios, l.porcentaje_comision,
               l.valor_comision, l.valor_a_pagar
        FROM   liquidacion_mensual l
        JOIN   alojamiento a ON a.id_alojamiento = l.id_alojamiento
        JOIN   municipio m   ON m.id_municipio   = a.id_municipio
        WHERE  l.periodo = TRUNC(TO_DATE(:per, 'YYYY-MM-DD'), 'MM')
        ORDER  BY l.valor_a_pagar DESC
    """, {"per": periodo}) if periodo else []

    return {"periodos": [p["periodo"] for p in periodos], "periodo": periodo,
            "liquidados": liquidados, "detalle": detalle}


@app.get("/api/gerencia/liquidaciones/{periodo}/{id_alojamiento}")
def detalle_liquidacion(periodo: str, id_alojamiento: int):
    # Las reservas que entraron en la liquidacion de un alojamiento, una por una
    reservas = consultar("""
        SELECT d.id_reserva, c.nombre AS cliente, c.documento,
               TO_CHAR(d.fecha_checkin, 'YYYY-MM-DD') AS fecha_checkin,
               TO_CHAR(d.fecha_checkout, 'YYYY-MM-DD') AS fecha_checkout,
               d.noches, d.valor_alojamiento, d.valor_servicios, d.valor_total
        FROM   liquidacion_detalle d
        JOIN   cliente c ON c.id_cliente = d.id_cliente
        WHERE  d.id_alojamiento = :aloj
          AND  d.periodo = TRUNC(TO_DATE(:per, 'YYYY-MM-DD'), 'MM')
        ORDER  BY d.fecha_checkout, d.id_reserva
    """, {"aloj": id_alojamiento, "per": periodo})
    return {"reservas": reservas}


@app.post("/api/gerencia/liquidar")
def liquidar(req: LiquidarRequest):
    return ejecutar_paquete("""
        BEGIN
          pkg_turismouq.sp_liquidar_mes(
            p_periodo => TO_DATE(:per, 'YYYY-MM-DD'), p_porcentaje => :pct);
        END;
    """, {"per": req.periodo, "pct": req.porcentaje})


@app.post("/api/gerencia/reabrir")
def reabrir(req: ReabrirRequest):
    return ejecutar_paquete("""
        BEGIN
          pkg_turismouq.sp_reabrir_liquidacion(p_periodo => TO_DATE(:per, 'YYYY-MM-DD'));
        END;
    """, {"per": req.periodo})


# =====================================================================
# 6. Auditoria
# =====================================================================
@app.get("/api/auditor/panel")
def panel_auditor():
    total = consultar("SELECT COUNT(*) AS n FROM auditoria_tarifa")[0]["n"]

    bitacora = consultar("""
        SELECT au.id_auditoria, au.operacion, au.valor_anterior, au.valor_nuevo,
               au.valor_nuevo - au.valor_anterior AS diferencia,
               ROUND((au.valor_nuevo - au.valor_anterior) * 100
                     / NULLIF(au.valor_anterior, 0), 1) AS pct_cambio,
               h.numero AS hab_numero, al.nombre AS alojamiento, m.nombre AS municipio,
               t.nombre AS temporada, au.usuario_bd, au.usuario_so, au.equipo,
               TO_CHAR(au.fecha_cambio, 'YYYY-MM-DD HH24:MI:SS') AS fecha_cambio
        FROM   auditoria_tarifa au
        LEFT   JOIN habitacion h   ON h.id_habitacion   = au.id_habitacion
        LEFT   JOIN alojamiento al ON al.id_alojamiento = h.id_alojamiento
        LEFT   JOIN municipio m    ON m.id_municipio    = al.id_municipio
        LEFT   JOIN temporada t    ON t.id_temporada    = au.id_temporada
        ORDER  BY au.id_auditoria DESC
        FETCH FIRST 60 ROWS ONLY
    """)

    pagos = consultar("""
        SELECT p.id_pago, p.id_reserva, c.nombre AS cliente, a.nombre AS alojamiento,
               TO_CHAR(p.fecha_pago, 'YYYY-MM-DD') AS fecha_pago, p.valor, p.metodo_pago
        FROM   pago p
        JOIN   reserva r ON r.id_reserva = p.id_reserva
        JOIN   cliente c ON c.id_cliente = r.id_cliente
        JOIN  (SELECT id_reserva, MIN(id_habitacion) AS id_habitacion
               FROM   reserva_habitacion GROUP BY id_reserva) rh ON rh.id_reserva = r.id_reserva
        JOIN   habitacion h  ON h.id_habitacion  = rh.id_habitacion
        JOIN   alojamiento a ON a.id_alojamiento = h.id_alojamiento
        ORDER  BY p.id_pago DESC
        FETCH FIRST 30 ROWS ONLY
    """)

    metodos = consultar("""
        SELECT metodo_pago, COUNT(*) AS transacciones,
               ROUND(SUM(valor) / 1000000, 1) AS total_millones
        FROM   pago
        GROUP  BY metodo_pago
        ORDER  BY total_millones DESC
    """)

    return {"total_registros": total, "bitacora": bitacora,
            "pagos": pagos, "metodos": metodos}


STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
os.makedirs(STATIC_DIR, exist_ok=True)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/")
def pagina_principal():
    return FileResponse(os.path.join(STATIC_DIR, "index.html"))
