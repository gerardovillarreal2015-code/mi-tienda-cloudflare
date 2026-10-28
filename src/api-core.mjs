// Lógica de la API de Mi Tienda. La usa Cloudflare Pages desde functions/api.js.
// Las claves llegan en "env" (variables de Cloudflare): DATABASE_URL (Neon) y ADMIN_KEY.
import { neon } from "@neondatabase/serverless";

let sql; // se crea en la primera petición con DATABASE_URL

// Columnas que se guardan al CREAR. El código del producto lo genera la base de datos.
const TABLAS = {
  categorias: ["nombre"],
  productos: ["nombre", "categoria_id", "precio_total_compra", "unidades_compra", "precio_venta"],
  inventario_movimientos: ["producto_id", "proveedor_id", "tipo", "lote", "cantidad", "precio_total", "fecha_vencimiento"],
  clientes: ["nombre", "telefono", "correo"],
  proveedores: ["empresa", "contacto", "telefono"],
  ventas: [],       // se crean con crearVenta (productos, stock y caja)
  abonos: [],       // se crean con crearAbono (deuda y caja)
  venta_items: [],  // solo lectura
  lotes: [],        // solo lectura (vencimientos)
  lotes_stock: [],  // solo lectura (lotes con unidades, para elegir en ventas)
  caja_movimientos: ["concepto", "tipo", "monto"],
};

// Columnas que se pueden cambiar al EDITAR (a una compra no se le cambia el producto; las ventas tienen su propia función)
const EDITABLES = {
  categorias: TABLAS.categorias,
  productos: TABLAS.productos,
  inventario_movimientos: ["proveedor_id", "tipo", "lote", "cantidad", "precio_total", "fecha_vencimiento"],
  clientes: TABLAS.clientes,
  proveedores: TABLAS.proveedores,
  caja_movimientos: TABLAS.caja_movimientos,
};

const ELIMINABLES = new Set(["categorias", "productos", "inventario_movimientos", "clientes", "proveedores", "ventas", "abonos", "caja_movimientos"]);

// Para leer, algunas tablas usan una vista con datos ya combinados
const LECTURA = {
  categorias: "v_categorias",
  productos: "v_productos",
  inventario_movimientos: "v_inventario",
  ventas: "v_ventas",
  clientes: "v_clientes",
  abonos: "v_abonos",
  venta_items: "v_venta_items",
  lotes: "v_lotes",
  lotes_stock: "v_lotes_stock",
};
const ORDEN = { lotes: "dias_restantes, id", lotes_stock: "producto_id, fecha_vencimiento NULLS LAST, id" }; // lo demás se lee del más nuevo al más antiguo

// Valores por defecto cuando el formulario deja un campo vacío
const DEFECTOS = {
  productos: { precio_total_compra: 0, unidades_compra: 1, precio_venta: 0 },
  inventario_movimientos: { precio_total: 0 },
};

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
const fallo = (msg) => json({ error: msg }, 400);

// Reglas de negocio de las tablas que se guardan directo
function validar(tabla, b) {
  if (tabla === "productos") {
    if (!(Number.isInteger(Number(b.unidades_compra)) && Number(b.unidades_compra) > 0))
      return "Las unidades compradas deben ser un número entero mayor a 0";
    if (!(Number(b.precio_total_compra) >= 0) || !(Number(b.precio_venta) >= 0))
      return "Los precios no pueden ser negativos";
  }
  if (tabla === "inventario_movimientos") {
    const cant = Number(b.cantidad);
    if (!Number.isInteger(cant) || cant === 0) return "La cantidad debe ser un número entero distinto de 0";
    if (b.tipo === "Compra" && cant <= 0) return "Una compra debe tener cantidad mayor a 0";
    if (!(Number(b.precio_total) >= 0)) return "El precio total no puede ser negativo";
  }
  return null;
}

// ¿El stock del producto sigue siendo >= 0 después de sumarle "delta"?
async function stockOk(producto_id, delta) {
  if (delta >= 0) return true;
  const r = await sql.query("SELECT stock FROM v_productos WHERE id = $1", [producto_id]);
  return r.length > 0 && r[0].stock + delta >= 0;
}
const SIN_STOCK = "No se puede: ya se vendieron unidades y el stock quedaría negativo";

// Los movimientos de caja de ventas y abonos se cambian desde su módulo
async function origenCaja(id) {
  const r = await sql.query("SELECT venta_id, abono_id FROM caja_movimientos WHERE id = $1", [id]);
  if (!r.length) return "El movimiento no existe";
  return r[0].venta_id || r[0].abono_id ? "Este movimiento viene de una venta o un abono: cámbialo desde ese módulo" : null;
}

// Venta con productos: el usuario escribe el precio de venta al público de cada línea y ELIGE EL LOTE del que sale.
// Valida stock y lote (solo lotes con unidades), calcula el total (precio x cantidad) y en UNA sola sentencia guarda
// la venta, sus productos con el precio y el COSTO DEL LOTE ELEGIDO (quedan fijos, no se vuelven a calcular),
// deja ese precio como precio actual del producto y registra en caja lo que se pagó ahora.
async function crearVenta(b) {
  const debe = Number(b.debe || 0);
  if (!(debe >= 0)) return fallo("El valor que debe no es válido");
  if (debe > 0 && !b.cliente_id) return fallo("Si el cliente debe algo, hay que elegir el cliente");

  const lineas = new Map();       // producto + lote + precio -> línea
  const porProducto = new Map();  // producto -> unidades
  const precios = new Map();      // producto -> último precio escrito
  for (const it of Array.isArray(b.items) ? b.items : []) {
    const id = Number(it.producto_id), cant = Number(it.cantidad), precio = Number(it.precio);
    const mov = it.movimiento_id ? Number(it.movimiento_id) : null;
    if (!Number.isInteger(id) || !Number.isInteger(cant) || cant <= 0 || (mov !== null && !Number.isInteger(mov)))
      return fallo("Cada producto debe tener una cantidad entera mayor a 0");
    if (!(precio > 0)) return fallo("Escribe el precio de venta al público de cada producto (mayor a 0)");
    const k = `${id}:${mov ?? ""}:${precio}`;
    const l = lineas.get(k) || { producto_id: id, movimiento_id: mov, cantidad: 0, precio };
    l.cantidad += cant;
    lineas.set(k, l);
    porProducto.set(id, (porProducto.get(id) || 0) + cant);
    precios.set(id, precio);
  }
  if (!lineas.size) return fallo("Agrega al menos un producto a la venta");

  const prods = await sql.query(
    "SELECT id, nombre, stock FROM v_productos WHERE id IN (SELECT jsonb_array_elements_text($1::jsonb)::int)",
    [JSON.stringify([...porProducto.keys()])]);
  if (prods.length !== porProducto.size) return fallo("Un producto de la venta no existe");
  for (const p of prods) {
    if (porProducto.get(p.id) > p.stock) return fallo(`No hay stock suficiente de ${p.nombre} (disponible: ${p.stock})`);
  }

  let total = 0;
  for (const l of lineas.values()) total += l.cantidad * l.precio;
  total = Math.round(total * 100) / 100;
  if (!(total > 0)) return fallo("El total de la venta debe ser mayor a 0");
  if (debe > total) return fallo("Lo que debe no puede ser mayor al total de la venta");

  // Cada línea debe salir de un lote de ese producto que todavía tenga unidades suficientes
  const disp = await sql.query(
    "SELECT id, producto_id, lote, restante FROM v_lotes_stock WHERE restante > 0 AND producto_id IN (SELECT jsonb_array_elements_text($1::jsonb)::int)",
    [JSON.stringify([...porProducto.keys()])]);
  const porId = new Map(disp.map((x) => [x.id, x]));
  const nombre = new Map(prods.map((p) => [p.id, p.nombre]));
  const pedido = new Map();
  for (const l of lineas.values()) {
    if (!l.movimiento_id) {
      if (disp.some((x) => x.producto_id === l.producto_id)) return fallo(`Elige el lote del que sale ${nombre.get(l.producto_id)}`);
      continue;
    }
    const lote = porId.get(l.movimiento_id);
    if (!lote || lote.producto_id !== l.producto_id) return fallo("El lote elegido no corresponde al producto o ya no tiene unidades");
    pedido.set(l.movimiento_id, (pedido.get(l.movimiento_id) || 0) + l.cantidad);
  }
  for (const [mid, cant] of pedido) {
    const lote = porId.get(mid);
    if (cant > lote.restante) return fallo(`No hay suficientes unidades en el lote ${lote.lote} (disponible: ${lote.restante})`);
  }

  const r = await sql.query(
    `WITH v AS (
       INSERT INTO ventas (cliente_id, debe, total) VALUES ($1, $2, $3) RETURNING id, total, debe
     ), it AS (
       INSERT INTO venta_items (venta_id, producto_id, movimiento_id, cantidad, precio_unitario, costo_unitario)
       SELECT v.id, x.producto_id, x.movimiento_id, x.cantidad, x.precio,
              COALESCE((SELECT ROUND(m.precio_total / m.cantidad, 2) FROM inventario_movimientos m
                        WHERE m.id = x.movimiento_id AND m.cantidad > 0), p.precio_compra)
       FROM v CROSS JOIN jsonb_to_recordset($4::jsonb) AS x(producto_id int, movimiento_id int, cantidad int, precio numeric)
       JOIN v_productos p ON p.id = x.producto_id
       RETURNING id
     ), up AS (
       UPDATE productos pr SET precio_venta = x.precio
       FROM jsonb_to_recordset($5::jsonb) AS x(producto_id int, precio numeric)
       WHERE pr.id = x.producto_id
       RETURNING pr.id
     ), cj AS (
       INSERT INTO caja_movimientos (concepto, tipo, monto, venta_id)
       SELECT 'Venta #' || v.id, 'Ingreso', v.total - v.debe, v.id FROM v WHERE v.total - v.debe > 0
       RETURNING id
     )
     SELECT id FROM v`,
    [b.cliente_id || null, debe, total, JSON.stringify([...lineas.values()]),
     JSON.stringify([...precios].map(([producto_id, precio]) => ({ producto_id, precio })))]);
  return json({ id: r[0].id, total, debe }, 201);
}

// Editar una venta: cliente y lo que debe. El ingreso en caja se ajusta solo.
async function editarVenta(id, b) {
  // El precio de venta y el costo quedan fijos desde que se registra la venta
  if (["items", "precio", "precio_unitario", "costo", "costo_unitario", "total"].some((k) => b[k] !== undefined))
    return fallo("El precio de venta y el costo no se pueden cambiar después de registrar la venta");
  const debe = Number(b.debe || 0);
  if (!(debe >= 0)) return fallo("El valor que debe no es válido");
  if (debe > 0 && !b.cliente_id) return fallo("Si el cliente debe algo, hay que elegir el cliente");
  const v = await sql.query("SELECT total FROM ventas WHERE id = $1", [id]);
  if (!v.length) return json({ error: "La venta no existe" }, 404);
  if (debe > Number(v[0].total)) return fallo("Lo que debe no puede ser mayor al total de la venta");
  await sql.query(
    `WITH v AS (
       UPDATE ventas SET cliente_id = $2, debe = $3 WHERE id = $1 RETURNING id, total, debe
     ), u AS (
       UPDATE caja_movimientos c SET monto = v.total - v.debe FROM v
       WHERE c.venta_id = v.id AND v.total - v.debe > 0 RETURNING c.id
     ), d AS (
       DELETE FROM caja_movimientos c USING v WHERE c.venta_id = v.id AND v.total - v.debe <= 0 RETURNING c.id
     ), i AS (
       INSERT INTO caja_movimientos (concepto, tipo, monto, venta_id)
       SELECT 'Venta #' || v.id, 'Ingreso', v.total - v.debe, v.id FROM v
       WHERE v.total - v.debe > 0 AND NOT EXISTS (SELECT 1 FROM caja_movimientos c WHERE c.venta_id = v.id)
       RETURNING id
     )
     SELECT id FROM v`,
    [id, b.cliente_id || null, debe]);
  return json({ id });
}

// Abono: no puede superar la deuda, y entra a caja como ingreso
async function crearAbono(b) {
  const monto = Number(b.monto);
  if (!(monto > 0)) return fallo("El abono debe ser mayor a 0");
  const d = await sql.query("SELECT deuda FROM v_clientes WHERE id = $1", [b.cliente_id]);
  if (!d.length) return fallo("Cliente no encontrado");
  if (monto > Number(d[0].deuda)) return fallo("El abono supera la deuda actual del cliente");
  const r = await sql.query(
    `WITH a AS (
       INSERT INTO abonos (cliente_id, monto) VALUES ($1, $2) RETURNING id, cliente_id, monto
     )
     INSERT INTO caja_movimientos (concepto, tipo, monto, abono_id)
     SELECT 'Abono de ' || c.nombre, 'Ingreso', a.monto, a.id FROM a JOIN clientes c ON c.id = a.cliente_id
     RETURNING abono_id AS id`,
    [b.cliente_id, monto]);
  return json(r[0], 201);
}

async function actualizar(tabla, id, b) {
  if (tabla === "ventas") return editarVenta(id, b);
  const cols = EDITABLES[tabla];
  if (!cols) return json({ error: "Este registro no se puede editar" }, 405);
  for (const [k, v] of Object.entries(DEFECTOS[tabla] || {})) b[k] ??= v;
  const problema = validar(tabla, b);
  if (problema) return fallo(problema);
  if (tabla === "caja_movimientos") {
    const o = await origenCaja(id);
    if (o) return fallo(o);
  }
  if (tabla === "inventario_movimientos") {
    const a = await sql.query("SELECT producto_id, cantidad FROM inventario_movimientos WHERE id = $1", [id]);
    if (!a.length) return json({ error: "El registro no existe" }, 404);
    if (!(await stockOk(a[0].producto_id, Number(b.cantidad) - a[0].cantidad))) return fallo(SIN_STOCK);
  }
  const sets = cols.map((c, i) => `${c} = $${i + 1}`).join(", ");
  const filas = await sql.query(
    `UPDATE ${tabla} SET ${sets} WHERE id = $${cols.length + 1} RETURNING id`,
    [...cols.map((c) => b[c] ?? null), id]);
  return filas.length ? json({ id }) : json({ error: "El registro no existe" }, 404);
}

async function eliminar(tabla, id) {
  if (!ELIMINABLES.has(tabla)) return json({ error: "Este registro no se puede eliminar" }, 405);
  let sentencia = `DELETE FROM ${tabla} WHERE id = $1 RETURNING id`;
  if (tabla === "ventas")
    sentencia = `WITH c AS (DELETE FROM caja_movimientos WHERE venta_id = $1),
                      i AS (DELETE FROM venta_items WHERE venta_id = $1)
                 DELETE FROM ventas WHERE id = $1 RETURNING id`;
  if (tabla === "abonos")
    sentencia = `WITH c AS (DELETE FROM caja_movimientos WHERE abono_id = $1)
                 DELETE FROM abonos WHERE id = $1 RETURNING id`;
  if (tabla === "caja_movimientos") {
    const o = await origenCaja(id);
    if (o) return fallo(o);
  }
  if (tabla === "inventario_movimientos") {
    const a = await sql.query("SELECT producto_id, cantidad FROM inventario_movimientos WHERE id = $1", [id]);
    if (a.length && !(await stockOk(a[0].producto_id, -a[0].cantidad))) return fallo(SIN_STOCK);
  }
  const r = await sql.query(sentencia, [id]);
  return r.length ? json({ id }) : json({ error: "El registro no existe" }, 404);
}

export async function manejar(req, env) {
  if (!env.DATABASE_URL || !env.ADMIN_KEY)
    return json({ error: "Falta configurar DATABASE_URL y ADMIN_KEY en el servidor" }, 500);
  if (req.headers.get("x-admin-key") !== env.ADMIN_KEY)
    return json({ error: "No autorizado" }, 401);

  const url = new URL(req.url);
  const tabla = url.searchParams.get("tabla");
  const idParam = url.searchParams.get("id");
  const id = idParam ? Number(idParam) : NaN;
  const cols = TABLAS[tabla];
  if (!cols) return json({ error: "Tabla no válida" }, 400);

  try {
    sql ??= neon(env.DATABASE_URL);
    if (req.method === "GET") {
      const origen = LECTURA[tabla] || tabla;
      return json(await sql.query(`SELECT * FROM ${origen} ORDER BY ${ORDEN[tabla] || "id DESC"} LIMIT 2000`));
    }
    if (req.method === "POST") {
      const body = await req.json();
      if (tabla === "ventas") return await crearVenta(body);
      if (tabla === "abonos") return await crearAbono(body);
      if (!cols.length) return json({ error: "Método no permitido" }, 405);
      for (const [k, v] of Object.entries(DEFECTOS[tabla] || {})) body[k] ??= v;
      const problema = validar(tabla, body);
      if (problema) return fallo(problema);
      if (tabla === "inventario_movimientos" && !(await stockOk(body.producto_id, Number(body.cantidad))))
        return fallo("No hay unidades suficientes para ese ajuste");
      const valores = cols.map((c) => body[c] ?? null);
      const marcas = cols.map((_, i) => `$${i + 1}`).join(",");
      const filas = await sql.query(
        `INSERT INTO ${tabla} (${cols.join(",")}) VALUES (${marcas}) RETURNING *`, valores);
      return json(filas[0], 201);
    }
    if (req.method === "PUT" || req.method === "DELETE") {
      if (!Number.isInteger(id)) return fallo("Falta el id del registro");
      return req.method === "PUT" ? await actualizar(tabla, id, await req.json()) : await eliminar(tabla, id);
    }
    return json({ error: "Método no permitido" }, 405);
  } catch (e) {
    if (e.code === "23503") return json({ error: "No se puede eliminar o guardar: tiene registros relacionados (por ejemplo productos, compras, ventas o abonos)" }, 409);
    if (e.code === "23505") return json({ error: "Ese registro ya existe" }, 409);
    if (e.code === "23514") return json({ error: "Los datos no cumplen las reglas (revisa los valores)" }, 400);
    return json({ error: "Error en la base de datos" }, 500);
  }
}
