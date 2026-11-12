"""
TurismoUQ - Servidor de la interfaz web.

Reglas de esta capa:
- No hay usuarios ni claves en el codigo. El personal (recepcion,
  administrador, gerente, auditor) inicia sesion con su propio usuario de
  Oracle y el servidor abre la conexion con ESE usuario: Oracle aplica sus
  roles, sus vistas por sede y los limites de su perfil.
- El portal del huesped usa el usuario PORTAL_WEB, que solo ve el catalogo y
  solo puede cotizar, registrarse y reservar. Su clave se lee del archivo
  .env (que no se sube al repositorio).
- El servidor solo LEE con SELECT. Todo cambio lo hace un procedimiento de
  la base de datos, que es donde estan las reglas. Si una regla se incumple,
  Oracle lanza un error propio (ORA-20xxx) y aqui solo se toma su mensaje.
"""
import os
import re
import secrets
import threading
from datetime import datetime, date
from typing import Optional

import oracledb
from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

app = FastAPI(title="TurismoUQ · Plataforma de Alojamientos y Reservas del Quindío",
              version="6.0.0")

# Solo la propia interfaz puede llamar a la API
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:8050", "http://localhost:8050"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# =====================================================================
# Configuracion (archivo .env junto a este archivo)
# =====================================================================
def leer_env() -> dict:
    ruta = os.path.join(os.path.dirname(__file__), ".env")
    valores = {}
    if os.path.exists(ruta):
        with open(ruta, encoding="utf-8") as f:
            for linea in f:
                linea = linea.strip()
                if linea and not linea.startswith("#") and "=" in linea:
                    clave, valor = linea.split("=", 1)
                    valores[clave.strip()] = valor.strip()
    return {**valores, **{k: v for k, v in os.environ.items() if k.startswith(("ORACLE_", "PORTAL_"))}}


CONFIG = leer_env()
DB_DSN = CONFIG.get("ORACLE_DSN", "localhost:1521/XEPDB1")
ESQUEMA = "TURISMOUQ"

# Rol de Oracle que exige cada perfil de la interfaz
ROL_DEL_PERFIL = {
    "recepcion": "ROL_RECEPCION",
    "admin": "ROL_ADMIN_ALOJAMIENTO",
    "gerente": "ROL_GERENTE",
    "auditor": "ROL_AUDITOR",
}


# =====================================================================
# Utilidades
# =====================================================================
def mensaje_oracle(err: Exception) -> str:
    """Deja solo el texto del error que lanzo la base de datos."""
    msg = str(err)
    propio = re.search(r"ORA-20\d{3}:\s*([^\n]+)", msg)
    if propio:
        return propio.group(1).strip()
    otro = re.search(r"((?:ORA|PLS)-\d{5}:\s*[^\n]+)", msg)
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


def preparar_conexion(conn):
    # Los objetos son de TURISMOUQ; asi no hay que escribir el esquema en cada
    # consulta. Los permisos siguen siendo los del usuario conectado.
    with conn.cursor() as cur:
        cur.execute(f"ALTER SESSION SET CURRENT_SCHEMA = {ESQUEMA}")


# =====================================================================
# Conexion del portal del huesped (usuario PORTAL_WEB)
# =====================================================================
pool_portal: Optional[oracledb.ConnectionPool] = None


def get_pool_portal() -> oracledb.ConnectionPool:
    global pool_portal
    if pool_portal is None:
        usuario, clave = CONFIG.get("PORTAL_USUARIO"), CONFIG.get("PORTAL_CLAVE")
        if not usuario or not clave:
            raise HTTPException(500, "Falta configurar PORTAL_USUARIO y PORTAL_CLAVE en webapp/.env")
        pool_portal = oracledb.create_pool(user=usuario, password=clave, dsn=DB_DSN,
                                           min=1, max=4, increment=1,
                                           session_callback=lambda c, t: preparar_conexion(c))
    return pool_portal


def portal_consultar(sql: str, params: Optional[dict] = None) -> list[dict]:
    with get_pool_portal().acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params or {})
            return filas(cur)


# =====================================================================
# Sesiones del personal: una conexion de Oracle por cada inicio de sesion
# =====================================================================
class Sesion:
    def __init__(self, usuario: str, perfil: str, conn):
        self.usuario = usuario
        self.perfil = perfil
        self.conn = conn
        self.lock = threading.Lock()


SESIONES: dict[str, Sesion] = {}

# Errores que significan que Oracle ya cerro la sesion (inactividad, tiempo
# maximo de conexion o la base se reinicio)
ERRORES_DE_SESION = ("ORA-02396", "ORA-02399", "ORA-03113", "ORA-03114", "ORA-03135",
                     "ORA-01012", "DPY-1001", "DPY-4011")


def obtener_sesion(token: Optional[str], perfil: str) -> Sesion:
    sesion = SESIONES.get((token or "").replace("Bearer ", ""))
    if sesion is None or sesion.perfil != perfil:
        raise HTTPException(401, "Inicie sesion para entrar a este perfil.")
    return sesion


def cerrar_sesion(token: str):
    sesion = SESIONES.pop(token, None)
    if sesion:
        try:
            sesion.conn.close()
        except Exception:
            pass


def ejecutar(sesion: Sesion, token: str, sql: str, params: Optional[dict] = None,
             leer: bool = True):
    """Ejecuta con la conexion del usuario. Si Oracle ya cerro la sesion,
    la borra y pide iniciar sesion de nuevo."""
    with sesion.lock:
        try:
            with sesion.conn.cursor() as cur:
                cur.execute(sql, params or {})
                return filas(cur) if leer else None
        except oracledb.Error as e:
            if any(codigo in str(e) for codigo in ERRORES_DE_SESION):
                cerrar_sesion(token.replace("Bearer ", ""))
                raise HTTPException(401, "Su sesion se cerro por inactividad o por tiempo. "
                                         "Inicie sesion de nuevo.")
            raise


def operar(sesion: Sesion, token: str, bloque: str, params: dict) -> dict:
    """Llama a un procedimiento del paquete de su rol."""
    try:
        ejecutar(sesion, token, bloque, params, leer=False)
        return {"ok": True}
    except HTTPException:
        raise
    except oracledb.Error as e:
        return {"ok": False, "mensaje": mensaje_oracle(e)}


# =====================================================================
# Datos que envia la pagina
# =====================================================================
class LoginRequest(BaseModel):
    perfil: str
    usuario: str
    clave: str


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
    anio: int
    porcentaje: float


class LiquidarRequest(BaseModel):
    periodo: str
    porcentaje: float = 12.0


class ReabrirRequest(BaseModel):
    periodo: str


# =====================================================================
# 1. Inicio y cierre de sesion del personal
# =====================================================================
@app.post("/api/login")
def iniciar_sesion(req: LoginRequest):
    rol = ROL_DEL_PERFIL.get(req.perfil)
    if not rol:
        raise HTTPException(400, "Perfil desconocido.")
    try:
        conn = oracledb.connect(user=req.usuario.strip(), password=req.clave, dsn=DB_DSN)
    except oracledb.Error as e:
        texto = str(e)
        if "ORA-01017" in texto:
            return {"ok": False, "mensaje": "Usuario o clave incorrectos."}
        if "ORA-28000" in texto:
            return {"ok": False, "mensaje": "La cuenta esta bloqueada por varios intentos fallidos. "
                                            "Espere 15 minutos o pida al administrador que la desbloquee."}
        if "ORA-02391" in texto:
            return {"ok": False, "mensaje": "Este usuario ya tiene abiertas las 2 sesiones que "
                                            "permite su perfil. Cierre una para entrar."}
        return {"ok": False, "mensaje": mensaje_oracle(e)}

    preparar_conexion(conn)
    with conn.cursor() as cur:
        cur.execute("SELECT role FROM session_roles")
        roles = {r[0] for r in cur.fetchall()}
    if rol not in roles:
        conn.close()
        return {"ok": False, "mensaje": f"El usuario {req.usuario.strip().lower()} no tiene el rol "
                                        f"{rol}, que es el que se necesita para este perfil."}

    sede = None
    if req.perfil in ("recepcion", "admin"):
        with conn.cursor() as cur:
            cur.execute("SELECT id_alojamiento, nombre, municipio, tipo FROM v_mi_sede")
            encontradas = filas(cur)
        sede = encontradas[0] if encontradas else None

    token = secrets.token_urlsafe(24)
    SESIONES[token] = Sesion(req.usuario.strip().lower(), req.perfil, conn)
    return {"ok": True, "token": token, "usuario": req.usuario.strip().lower(),
            "perfil": req.perfil, "sede": sede}


@app.post("/api/logout")
def terminar_sesion(authorization: Optional[str] = Header(None)):
    cerrar_sesion((authorization or "").replace("Bearer ", ""))
    return {"ok": True}


# =====================================================================
# 2. Portal del huesped (usuario PORTAL_WEB)
# =====================================================================
@app.get("/api/init")
def datos_iniciales():
    municipios = portal_consultar("""
        SELECT m.id_municipio, m.nombre, COUNT(a.id_alojamiento) AS total_alojamientos
        FROM   municipio m
        LEFT   JOIN v_catalogo_alojamientos a ON a.id_municipio = m.id_municipio
        GROUP  BY m.id_municipio, m.nombre
        ORDER  BY m.nombre
    """)
    tipos = portal_consultar("SELECT id_tipo, nombre FROM tipo_alojamiento ORDER BY nombre")
    alojamientos = portal_consultar("SELECT * FROM v_catalogo_alojamientos ORDER BY municipio, nombre")
    return {"municipios": municipios, "tipos": tipos, "alojamientos": alojamientos}


@app.get("/api/alojamientos/{id_alojamiento}")
def detalle_alojamiento(id_alojamiento: int):
    habitaciones = portal_consultar("""
        SELECT id_habitacion, numero, tipo_habitacion, estado, capacidad
        FROM   v_catalogo_habitaciones
        WHERE  id_alojamiento = :id
        ORDER  BY numero
    """, {"id": id_alojamiento})
    servicios = portal_consultar("""
        SELECT id_servicio, nombre, valor
        FROM   v_catalogo_servicios
        WHERE  id_alojamiento = :id
        ORDER  BY nombre
    """, {"id": id_alojamiento})
    return {"habitaciones": habitaciones, "servicios": servicios}


@app.get("/api/clientes/buscar")
def buscar_cliente(documento: str = Query(...)):
    with get_pool_portal().acquire() as conn:
        with conn.cursor() as cur:
            id_cliente, nombre = cur.var(int), cur.var(str)
            cur.execute("""
                BEGIN
                  pkg_portal.sp_buscar_cliente(p_documento  => :doc,
                                               p_id_cliente => :id,
                                               p_nombre     => :nom);
                END;
            """, {"doc": documento.strip(), "id": id_cliente, "nom": nombre})
    if id_cliente.getvalue() is None:
        return {"encontrado": False, "cliente": None}
    return {"encontrado": True, "cliente": {"id_cliente": id_cliente.getvalue(),
                                            "nombre": nombre.getvalue(),
                                            "documento": documento.strip()}}


@app.post("/api/clientes/crear")
def registrar_cliente(req: NuevoClienteRequest):
    with get_pool_portal().acquire() as conn:
        with conn.cursor() as cur:
            try:
                id_cliente = cur.var(int)
                cur.execute("""
                    BEGIN
                      pkg_portal.sp_registrar_cliente(p_nombre     => :nom,
                                                      p_documento  => :doc,
                                                      p_email      => :em,
                                                      p_id_cliente => :id);
                    END;
                """, {"nom": req.nombre, "doc": req.documento, "em": req.email, "id": id_cliente})
                return {"ok": True, "cliente": {"id_cliente": id_cliente.getvalue(),
                                                "nombre": req.nombre.strip(),
                                                "documento": req.documento.strip()}}
            except oracledb.Error as e:
                return {"ok": False, "mensaje": mensaje_oracle(e)}


@app.post("/api/reservas/cotizar")
def cotizar_estadia(req: CotizarRequest):
    params = {"hab": req.id_habitacion, "fin": req.fecha_in, "fout": req.fecha_out}
    with get_pool_portal().acquire() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute("""
                    SELECT pkg_portal.fn_valor_estadia(:hab, TO_DATE(:fin, 'YYYY-MM-DD'),
                                                       TO_DATE(:fout, 'YYYY-MM-DD')),
                           pkg_portal.fn_disponible(:hab, TO_DATE(:fin, 'YYYY-MM-DD'),
                                                    TO_DATE(:fout, 'YYYY-MM-DD'))
                    FROM   dual
                """, params)
                valor_total, libre = cur.fetchone()

                cur.execute("""
                    SELECT temporada, tipo_temporada, valor_noche AS tarifa_noche,
                           LEAST(TO_DATE(:fout, 'YYYY-MM-DD') - 1, fecha_fin)
                             - GREATEST(TO_DATE(:fin, 'YYYY-MM-DD'), fecha_inicio) + 1 AS noches
                    FROM   v_catalogo_tarifas
                    WHERE  id_habitacion = :hab
                      AND  fecha_inicio <= TO_DATE(:fout, 'YYYY-MM-DD') - 1
                      AND  fecha_fin    >= TO_DATE(:fin, 'YYYY-MM-DD')
                    ORDER  BY fecha_inicio
                """, params)
                tramos = filas(cur)
                for t in tramos:
                    t["subtotal"] = t["noches"] * t["tarifa_noche"]

                return {"ok": True, "valor_total": float(valor_total), "disponible": libre == 1,
                        "noches_totales": sum(t["noches"] for t in tramos), "tramos": tramos}
            except oracledb.Error as e:
                return {"ok": False, "mensaje": mensaje_oracle(e)}


@app.post("/api/reservas/crear")
def crear_reserva(req: CrearReservaRequest):
    with get_pool_portal().acquire() as conn:
        with conn.cursor() as cur:
            try:
                id_reserva = cur.var(int)
                cur.execute("""
                    BEGIN
                      pkg_portal.sp_crear_reserva(
                        p_id_cliente    => :cli,
                        p_id_habitacion => :hab,
                        p_fecha_in      => TO_DATE(:fin, 'YYYY-MM-DD'),
                        p_fecha_out     => TO_DATE(:fout, 'YYYY-MM-DD'),
                        p_num_huespedes => :hues,
                        p_id_reserva    => :id);
                    END;
                """, {"cli": req.id_cliente, "hab": req.id_habitacion, "fin": req.fecha_in,
                      "fout": req.fecha_out, "hues": req.num_huespedes, "id": id_reserva})
            except oracledb.Error as e:
                return {"ok": False, "mensaje": mensaje_oracle(e)}

    # El portal no puede leer la tabla de reservas: la confirmacion se arma con
    # lo que se pidio y con el catalogo
    detalle = portal_consultar("""
        SELECT h.numero AS hab_numero, a.nombre AS alojamiento, a.municipio,
               pkg_portal.fn_valor_estadia(h.id_habitacion, TO_DATE(:fin, 'YYYY-MM-DD'),
                                           TO_DATE(:fout, 'YYYY-MM-DD')) AS valor_total
        FROM   v_catalogo_habitaciones h
        JOIN   v_catalogo_alojamientos a ON a.id_alojamiento = h.id_alojamiento
        WHERE  h.id_habitacion = :hab
    """, {"hab": req.id_habitacion, "fin": req.fecha_in, "fout": req.fecha_out})[0]
    reserva = {"id_reserva": id_reserva.getvalue(), "fecha_checkin": req.fecha_in,
               "fecha_checkout": req.fecha_out, "num_huespedes": req.num_huespedes, **detalle}
    return {"ok": True, "id_reserva": id_reserva.getvalue(), "reserva": reserva}


# =====================================================================
# 3. Recepcion (usuario con ROL_RECEPCION: solo vistas de su sede)
# =====================================================================
VISTAS_RECEPCION = {
    "llegadas": ("estado = 'CONFIRMADA' AND fecha_checkin = TRUNC(SYSDATE)",
                 "id_reserva"),
    "alojados": ("estado = 'CONFIRMADA' AND fecha_checkin <= TRUNC(SYSDATE) "
                 "AND fecha_checkout > TRUNC(SYSDATE)",
                 "fecha_checkout, id_reserva"),
    "salidas":  ("estado = 'CONFIRMADA' AND fecha_checkout <= TRUNC(SYSDATE)",
                 "fecha_checkout DESC, id_reserva"),
    "proximas": ("estado = 'CONFIRMADA' AND fecha_checkin > TRUNC(SYSDATE) "
                 "AND fecha_checkin <= TRUNC(SYSDATE) + 7",
                 "fecha_checkin, id_reserva"),
    "todas":    ("1 = 1", "fecha_checkin DESC, id_reserva DESC"),
}

COLUMNAS_RESERVA = """
    id_reserva, cliente, documento, habitaciones,
    TO_CHAR(fecha_checkin, 'YYYY-MM-DD') AS fecha_checkin,
    TO_CHAR(fecha_checkout, 'YYYY-MM-DD') AS fecha_checkout,
    fecha_checkout - fecha_checkin AS noches, num_huespedes, estado,
    valor_total, pagado, saldo,
    CASE WHEN estado = 'CONFIRMADA' AND fecha_checkin <= TRUNC(SYSDATE) THEN 1 ELSE 0 END AS puede_checkout,
    CASE WHEN estado = 'CONFIRMADA' AND fecha_checkin >  TRUNC(SYSDATE) THEN 1 ELSE 0 END AS puede_cancelar
"""


@app.get("/api/recepcion/resumen")
def resumen_recepcion(authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "recepcion")
    columnas = ", ".join(f"SUM(CASE WHEN {cond} THEN 1 ELSE 0 END) AS {vista}"
                         for vista, (cond, _) in VISTAS_RECEPCION.items() if vista != "todas")
    fila = ejecutar(s, authorization, f"SELECT {columnas} FROM v_sede_reservas")[0]
    return {k: v or 0 for k, v in fila.items()}


@app.get("/api/recepcion/reservas")
def reservas_recepcion(vista: str = Query("llegadas"), busqueda: Optional[str] = Query(None),
                       authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "recepcion")
    condicion, orden = VISTAS_RECEPCION.get(vista, VISTAS_RECEPCION["llegadas"])
    params = {}
    if busqueda and busqueda.strip():
        condicion += (" AND (UPPER(cliente) LIKE UPPER(:q) OR documento LIKE :q "
                      "OR TO_CHAR(id_reserva) = :qexacta)")
        params = {"q": f"%{busqueda.strip()}%", "qexacta": busqueda.strip()}
    reservas = ejecutar(s, authorization, f"""
        SELECT {COLUMNAS_RESERVA}
        FROM   v_sede_reservas
        WHERE  {condicion}
        ORDER  BY {orden}
        FETCH FIRST 50 ROWS ONLY
    """, params)
    return {"reservas": reservas}


@app.get("/api/recepcion/reservas/{id_reserva}")
def cuenta_reserva(id_reserva: int, authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "recepcion")
    cabecera = ejecutar(s, authorization,
                        f"SELECT {COLUMNAS_RESERVA} FROM v_sede_reservas WHERE id_reserva = :id",
                        {"id": id_reserva})
    if not cabecera:
        return {"ok": False, "mensaje": f"La reserva {id_reserva} no existe o no es de su sede."}
    estadia = ejecutar(s, authorization, """
        SELECT hab_numero, temporada, tipo_temporada, noches, valor_noche_aplicado, subtotal
        FROM   v_sede_estadias
        WHERE  id_reserva = :id
        ORDER  BY hab_numero, fecha_inicio
    """, {"id": id_reserva})
    consumos = ejecutar(s, authorization, """
        SELECT servicio, cantidad, valor_unitario, valor_total
        FROM   v_sede_consumos
        WHERE  id_reserva = :id
        ORDER  BY id_reserva_servicio
    """, {"id": id_reserva})
    servicios = ejecutar(s, authorization,
                         "SELECT id_servicio, nombre, valor FROM v_sede_servicios ORDER BY nombre")
    return {"ok": True, "reserva": cabecera[0], "estadia": estadia,
            "consumos": consumos, "servicios_disponibles": servicios}


@app.post("/api/recepcion/reservas/{id_reserva}/servicios")
def agregar_servicio(id_reserva: int, req: ServicioRequest,
                     authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "recepcion")
    return operar(s, authorization, """
        BEGIN
          pkg_recepcion.sp_agregar_servicio(p_id_reserva => :res, p_id_servicio => :srv,
                                            p_cantidad => :cant);
        END;
    """, {"res": id_reserva, "srv": req.id_servicio, "cant": req.cantidad})


@app.post("/api/recepcion/reservas/{id_reserva}/checkout")
def checkout(id_reserva: int, req: CheckoutRequest, authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "recepcion")
    return operar(s, authorization, """
        BEGIN
          pkg_recepcion.sp_checkout(p_id_reserva => :res, p_metodo_pago => :met);
        END;
    """, {"res": id_reserva, "met": req.metodo_pago})


@app.post("/api/recepcion/reservas/{id_reserva}/cancelar")
def cancelar(id_reserva: int, authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "recepcion")
    return operar(s, authorization, """
        BEGIN
          pkg_recepcion.sp_cancelar_reserva(p_id_reserva => :res);
        END;
    """, {"res": id_reserva})


# =====================================================================
# 4. Administrador de alojamiento (ROL_ADMIN_ALOJAMIENTO: su sede)
# =====================================================================
@app.get("/api/admin/panel")
def panel_admin(authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "admin")
    habitaciones = ejecutar(s, authorization, """
        SELECT h.id_habitacion, h.numero, h.tipo_habitacion, h.estado, h.capacidad,
               CASE WHEN h.ocupada_hoy = 'SI' THEN 1 ELSE 0 END AS ocupada_hoy,
               MIN(t.valor_noche) AS tarifa_baja, MAX(t.valor_noche) AS tarifa_alta
        FROM   v_sede_habitaciones h
        LEFT   JOIN v_sede_tarifas t ON t.id_habitacion = h.id_habitacion
        GROUP  BY h.id_habitacion, h.numero, h.tipo_habitacion, h.estado, h.capacidad, h.ocupada_hoy
        ORDER  BY h.numero
    """)
    tarifas = ejecutar(s, authorization, """
        SELECT id_tarifa, id_habitacion, habitacion AS hab_numero, temporada,
               tipo AS tipo_temporada,
               TO_CHAR(fecha_inicio, 'YYYY-MM-DD') AS fecha_inicio,
               TO_CHAR(fecha_fin, 'YYYY-MM-DD') AS fecha_fin,
               EXTRACT(YEAR FROM fecha_inicio) AS anio, valor_noche,
               CASE WHEN editable = 'SI' THEN 1 ELSE 0 END AS editable
        FROM   v_sede_tarifas
        WHERE  fecha_fin >= TRUNC(SYSDATE, 'YYYY')
        ORDER  BY habitacion, fecha_inicio
    """)
    servicios = ejecutar(s, authorization,
                         "SELECT id_servicio, nombre, valor FROM v_sede_servicios ORDER BY nombre")
    return {"habitaciones": habitaciones, "tarifas": tarifas, "servicios": servicios}


@app.post("/api/admin/habitaciones/{id_habitacion}/estado")
def cambiar_estado_habitacion(id_habitacion: int, req: EstadoHabitacionRequest,
                              authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "admin")
    return operar(s, authorization, """
        BEGIN
          pkg_administracion.sp_cambiar_estado_habitacion(p_id_habitacion => :hab,
                                                          p_estado => :est);
        END;
    """, {"hab": id_habitacion, "est": req.estado})


@app.post("/api/admin/tarifas/{id_tarifa}")
def actualizar_tarifa(id_tarifa: int, req: TarifaRequest,
                      authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "admin")
    return operar(s, authorization, """
        BEGIN
          pkg_administracion.sp_actualizar_tarifa(p_id_tarifa => :id, p_valor_noche => :val);
        END;
    """, {"id": id_tarifa, "val": req.valor_noche})


@app.post("/api/admin/tarifas-ajuste")
def ajustar_tarifas(req: AjusteTarifasRequest, authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "admin")
    with s.lock:
        try:
            with s.conn.cursor() as cur:
                afectadas = cur.var(int)
                cur.execute("""
                    BEGIN
                      pkg_administracion.sp_ajustar_tarifas(p_anio => :anio, p_porcentaje => :pct,
                                                            p_afectadas => :afec);
                    END;
                """, {"anio": req.anio, "pct": req.porcentaje, "afec": afectadas})
                return {"ok": True, "afectadas": afectadas.getvalue()}
        except oracledb.Error as e:
            return {"ok": False, "mensaje": mensaje_oracle(e)}


# =====================================================================
# 5. Gerencia (ROL_GERENTE: lectura de todo el negocio)
# =====================================================================
@app.get("/api/gerencia/resumen")
def resumen_gerencia(anio: int = Query(2025), authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "gerente")
    q = lambda sql, p=None: ejecutar(s, authorization, sql, p)

    kpis = q("""
        SELECT COUNT(DISTINCT r.id_reserva) AS reservas,
               SUM(rh.noches) AS noches,
               ROUND(SUM(rh.noches * rh.valor_noche_aplicado) / 1000000, 1) AS ingresos_aloj_mill
        FROM   reserva r
        JOIN   reserva_habitacion rh ON rh.id_reserva = r.id_reserva
        WHERE  r.estado <> 'CANCELADA'
          AND  EXTRACT(YEAR FROM r.fecha_checkin) = :anio
    """, {"anio": anio})[0]
    kpis.update(q("""
        SELECT ROUND(SUM(rs.valor_total) / 1000000, 1) AS ingresos_serv_mill
        FROM   reserva_servicio rs
        JOIN   reserva r ON r.id_reserva = rs.id_reserva
        WHERE  r.estado <> 'CANCELADA'
          AND  EXTRACT(YEAR FROM r.fecha_checkin) = :anio
    """, {"anio": anio})[0])
    kpis.update(q("""
        SELECT ROUND(AVG(rs.calificacion), 2) AS calificacion
        FROM   resena rs
        JOIN   reserva r ON r.id_reserva = rs.id_reserva
        WHERE  EXTRACT(YEAR FROM r.fecha_checkin) = :anio
    """, {"anio": anio})[0])

    # Consulta 1 de la Entrega 1: ocupacion por municipio y mes con PIVOT
    ocupacion = q("""
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
    evolucion = q("""
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
    ranking = q("""
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
    promocion = q("""
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
def liquidaciones(periodo: Optional[str] = Query(None), authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "gerente")
    # Meses que se pueden liquidar: ya terminados y con estadias finalizadas
    periodos = ejecutar(s, authorization, """
        SELECT DISTINCT TO_CHAR(TRUNC(fecha_checkout, 'MM'), 'YYYY-MM-DD') AS periodo
        FROM   reserva
        WHERE  estado = 'FINALIZADA'
          AND  fecha_checkout < TRUNC(SYSDATE, 'MM')
        ORDER  BY periodo DESC
        FETCH FIRST 24 ROWS ONLY
    """)
    periodo = periodo or (periodos[0]["periodo"] if periodos else None)

    liquidados = ejecutar(s, authorization, """
        SELECT TO_CHAR(periodo, 'YYYY-MM-DD') AS periodo,
               COUNT(*) AS alojamientos,
               MAX(porcentaje_comision) AS porcentaje_comision,
               SUM(valor_comision) AS total_comision,
               SUM(valor_a_pagar) AS total_pagar
        FROM   liquidacion_mensual
        GROUP  BY periodo
        ORDER  BY periodo DESC
    """)

    detalle = ejecutar(s, authorization, """
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
def detalle_liquidacion(periodo: str, id_alojamiento: int,
                        authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "gerente")
    # Las reservas que entraron en la liquidacion de un alojamiento, una por una
    reservas = ejecutar(s, authorization, """
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
def liquidar(req: LiquidarRequest, authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "gerente")
    return operar(s, authorization, """
        BEGIN
          pkg_gerencia.sp_liquidar_mes(p_periodo => TO_DATE(:per, 'YYYY-MM-DD'),
                                       p_porcentaje => :pct);
        END;
    """, {"per": req.periodo, "pct": req.porcentaje})


@app.post("/api/gerencia/reabrir")
def reabrir(req: ReabrirRequest, authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "gerente")
    return operar(s, authorization, """
        BEGIN
          pkg_gerencia.sp_reabrir_liquidacion(p_periodo => TO_DATE(:per, 'YYYY-MM-DD'));
        END;
    """, {"per": req.periodo})


# =====================================================================
# 6. Auditoria (ROL_AUDITOR: solo lectura de lo que se audita)
# =====================================================================
@app.get("/api/auditor/panel")
def panel_auditor(authorization: Optional[str] = Header(None)):
    s = obtener_sesion(authorization, "auditor")
    q = lambda sql: ejecutar(s, authorization, sql)

    total = q("SELECT COUNT(*) AS n FROM auditoria_tarifa")[0]["n"]
    bitacora = q("""
        SELECT id_auditoria, operacion, valor_anterior, valor_nuevo, diferencia, pct_cambio,
               hab_numero, alojamiento, municipio, temporada, usuario_bd, usuario_so, equipo,
               TO_CHAR(fecha_cambio, 'YYYY-MM-DD HH24:MI:SS') AS fecha_cambio
        FROM   v_aud_cambios_tarifa
        ORDER  BY id_auditoria DESC
        FETCH FIRST 60 ROWS ONLY
    """)
    pagos = q("""
        SELECT id_pago, id_reserva, alojamiento,
               TO_CHAR(fecha_pago, 'YYYY-MM-DD') AS fecha_pago, valor, metodo_pago
        FROM   v_aud_pagos
        ORDER  BY id_pago DESC
        FETCH FIRST 30 ROWS ONLY
    """)
    metodos = q("""
        SELECT metodo_pago, COUNT(*) AS transacciones,
               ROUND(SUM(valor) / 1000000, 1) AS total_millones
        FROM   pago
        GROUP  BY metodo_pago
        ORDER  BY total_millones DESC
    """)
    intentos = q("""
        SELECT id_log, operacion, id_cliente, id_habitacion,
               TO_CHAR(fecha_in, 'YYYY-MM-DD') AS fecha_in,
               TO_CHAR(fecha_out, 'YYYY-MM-DD') AS fecha_out,
               codigo_error, mensaje, usuario_bd,
               TO_CHAR(fecha_error, 'YYYY-MM-DD HH24:MI:SS') AS fecha_error
        FROM   log_errores_reserva
        ORDER  BY id_log DESC
        FETCH FIRST 50 ROWS ONLY
    """)
    return {"total_registros": total, "bitacora": bitacora, "pagos": pagos,
            "metodos": metodos, "intentos": intentos}


STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
os.makedirs(STATIC_DIR, exist_ok=True)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/")
def pagina_principal():
    return FileResponse(os.path.join(STATIC_DIR, "index.html"))
