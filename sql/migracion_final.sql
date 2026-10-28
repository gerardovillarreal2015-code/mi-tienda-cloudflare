-- =====================================================================
--  MI TIENDA · MIGRACIÓN FINAL (reemplaza schema.sql y las migraciones anteriores)
--  Neon > SQL Editor > pegar todo > Run
--
--  • Sirve para una base NUEVA y para una que ya tenga versiones anteriores.
--  • Se puede ejecutar más de una vez sin duplicar nada.
--  • Convierte los datos existentes:
--      - productos: el precio de compra anterior pasa a "precio total de compra" (1 unidad)
--      - inventario: costo unitario x cantidad pasa a "precio total"
--      - ventas: las que eran "Crédito" quedan con debe = total
--    y elimina las columnas viejas (stock, precio_compra, costo_unitario, tipo_pago).
-- =====================================================================

-- 0) Quitar las vistas para recrearlas al final (no guardan datos)
DROP VIEW IF EXISTS v_lotes_stock, v_costo_inventario, v_abonos, v_lotes, v_venta_items, v_ventas, v_clientes, v_inventario, v_productos, v_categorias;

-- 1) Tablas base (en orden de dependencia)
CREATE TABLE IF NOT EXISTS categorias (
  id SERIAL PRIMARY KEY,
  nombre TEXT NOT NULL UNIQUE);

CREATE TABLE IF NOT EXISTS proveedores (
  id SERIAL PRIMARY KEY,
  empresa TEXT NOT NULL, contacto TEXT, telefono TEXT,
  creado TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS clientes (
  id SERIAL PRIMARY KEY,
  nombre TEXT NOT NULL, telefono TEXT, correo TEXT,
  creado TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS productos (
  id SERIAL PRIMARY KEY,
  codigo TEXT, nombre TEXT NOT NULL,
  creado TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS ventas (
  id SERIAL PRIMARY KEY,
  cliente_id INT REFERENCES clientes(id),
  total NUMERIC(12,2) DEFAULT 0,
  fecha TIMESTAMPTZ DEFAULT now());          -- se guarda en UTC; la página la muestra en hora de Colombia

CREATE TABLE IF NOT EXISTS abonos (
  id SERIAL PRIMARY KEY,
  cliente_id INT NOT NULL REFERENCES clientes(id),
  monto NUMERIC(12,2) NOT NULL CHECK (monto > 0),
  fecha TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS inventario_movimientos (
  id SERIAL PRIMARY KEY,
  producto_id INT NOT NULL REFERENCES productos(id),
  proveedor_id INT REFERENCES proveedores(id),
  tipo TEXT NOT NULL CHECK (tipo IN ('Compra','Ajuste')),
  cantidad INT NOT NULL,
  fecha TIMESTAMPTZ DEFAULT now());

CREATE TABLE IF NOT EXISTS venta_items (
  id SERIAL PRIMARY KEY,
  venta_id INT NOT NULL REFERENCES ventas(id),
  producto_id INT NOT NULL REFERENCES productos(id),
  cantidad INT NOT NULL CHECK (cantidad > 0),
  precio_unitario NUMERIC(12,2) NOT NULL,             -- precio de venta al público en el momento de la venta
  costo_unitario NUMERIC(12,2) NOT NULL DEFAULT 0);   -- precio unitario de compra en el momento de la venta

CREATE TABLE IF NOT EXISTS caja_movimientos (
  id SERIAL PRIMARY KEY,
  concepto TEXT NOT NULL,
  tipo TEXT CHECK (tipo IN ('Ingreso','Egreso')),
  monto NUMERIC(12,2) NOT NULL,
  fecha TIMESTAMPTZ DEFAULT now());

-- 2) PRODUCTOS: precio total de compra + unidades compradas (el precio unitario se calcula en la vista)
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'productos' AND column_name = 'precio') THEN
    ALTER TABLE productos RENAME COLUMN precio TO precio_venta;
  END IF;
END $$;
ALTER TABLE productos DROP COLUMN IF EXISTS stock;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS categoria_id INT REFERENCES categorias(id);
ALTER TABLE productos ADD COLUMN IF NOT EXISTS precio_venta NUMERIC(12,2) DEFAULT 0;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS stock_minimo INT DEFAULT 5;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS precio_total_compra NUMERIC(12,2) NOT NULL DEFAULT 0;
ALTER TABLE productos ADD COLUMN IF NOT EXISTS unidades_compra INT NOT NULL DEFAULT 1 CHECK (unidades_compra > 0);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'productos' AND column_name = 'precio_compra') THEN
    UPDATE productos SET precio_total_compra = COALESCE(precio_compra, 0);
    ALTER TABLE productos DROP COLUMN precio_compra;
  END IF;
END $$;

-- Código de producto automático: P-0001, P-0002…  (los códigos que ya existían se respetan)
CREATE SEQUENCE IF NOT EXISTS productos_codigo_seq;
ALTER TABLE productos ALTER COLUMN codigo SET DEFAULT 'P-' || lpad(nextval('productos_codigo_seq')::text, 4, '0');
UPDATE productos SET codigo = 'P-' || lpad(nextval('productos_codigo_seq')::text, 4, '0') WHERE codigo IS NULL OR codigo = '';

-- 3) INVENTARIO: precio total pagado + unidades (cantidad); el precio unitario se calcula en la vista
ALTER TABLE inventario_movimientos ADD COLUMN IF NOT EXISTS fecha_vencimiento DATE;
ALTER TABLE inventario_movimientos ADD COLUMN IF NOT EXISTS lote TEXT;   -- N° de lote (si se deja vacío, la lista muestra L-<id>)
ALTER TABLE inventario_movimientos ADD COLUMN IF NOT EXISTS precio_total NUMERIC(12,2) NOT NULL DEFAULT 0;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'inventario_movimientos' AND column_name = 'costo_unitario') THEN
    UPDATE inventario_movimientos SET precio_total = COALESCE(costo_unitario, 0) * cantidad WHERE cantidad > 0;
    ALTER TABLE inventario_movimientos DROP COLUMN costo_unitario;
  END IF;
END $$;

-- 4) VENTAS: "debe" = lo que quedó fiado en esa venta (0 si pagó todo)
ALTER TABLE ventas ADD COLUMN IF NOT EXISTS debe NUMERIC(12,2) NOT NULL DEFAULT 0;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = current_schema() AND table_name = 'ventas' AND column_name = 'tipo_pago') THEN
    UPDATE ventas SET debe = COALESCE(total, 0) WHERE tipo_pago = 'Crédito';
    ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_credito_requiere_cliente;
    ALTER TABLE ventas DROP COLUMN tipo_pago;
  END IF;
END $$;
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_debe_valido;
ALTER TABLE ventas ADD CONSTRAINT ventas_debe_valido CHECK (debe >= 0 AND debe <= total);
ALTER TABLE ventas DROP CONSTRAINT IF EXISTS ventas_debe_requiere_cliente;
ALTER TABLE ventas ADD CONSTRAINT ventas_debe_requiere_cliente CHECK (debe = 0 OR cliente_id IS NOT NULL);

-- 5) CAJA: de dónde viene cada ingreso automático
ALTER TABLE caja_movimientos ADD COLUMN IF NOT EXISTS venta_id INT REFERENCES ventas(id);
ALTER TABLE caja_movimientos ADD COLUMN IF NOT EXISTS abono_id INT REFERENCES abonos(id);

-- VENTAS: de qué lote sale cada producto vendido (si queda vacío, se descuenta del lote que vence primero)
ALTER TABLE venta_items ADD COLUMN IF NOT EXISTS movimiento_id INT REFERENCES inventario_movimientos(id);
-- Ventas anteriores: si el producto tiene una sola compra, todas sus ventas salieron de ese lote
UPDATE venta_items i SET movimiento_id = m.id
FROM inventario_movimientos m
WHERE i.movimiento_id IS NULL AND m.producto_id = i.producto_id AND m.cantidad > 0
  AND (SELECT COUNT(*) FROM inventario_movimientos m2 WHERE m2.producto_id = i.producto_id AND m2.cantidad > 0) = 1;

-- Opcional: que el código de producto no se repita (los vacíos sí se permiten).
-- Descomenta solo si tus productos no tienen códigos repetidos.
-- CREATE UNIQUE INDEX IF NOT EXISTS uq_productos_codigo ON productos(codigo);

-- 6) Índices en las llaves foráneas
CREATE INDEX IF NOT EXISTS idx_productos_categoria ON productos(categoria_id);
CREATE INDEX IF NOT EXISTS idx_mov_producto        ON inventario_movimientos(producto_id);
CREATE INDEX IF NOT EXISTS idx_mov_proveedor       ON inventario_movimientos(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_ventas_cliente      ON ventas(cliente_id);
CREATE INDEX IF NOT EXISTS idx_abonos_cliente      ON abonos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_items_venta         ON venta_items(venta_id);
CREATE INDEX IF NOT EXISTS idx_items_producto      ON venta_items(producto_id);
CREATE INDEX IF NOT EXISTS idx_items_movimiento    ON venta_items(movimiento_id);
CREATE INDEX IF NOT EXISTS idx_caja_venta          ON caja_movimientos(venta_id);
CREATE INDEX IF NOT EXISTS idx_caja_abono          ON caja_movimientos(abono_id);

-- 7) Datos iniciales
INSERT INTO categorias (nombre) VALUES ('Licores'),('Bebidas'),('Mecatos'),('Aseo'),('Otros')
  ON CONFLICT (nombre) DO NOTHING;

-- 8) Vistas (lo que lee la página)
CREATE VIEW v_categorias AS
  SELECT c.id, c.nombre, COUNT(p.id)::int AS productos
  FROM categorias c LEFT JOIN productos p ON p.categoria_id = c.id
  GROUP BY c.id, c.nombre;

-- Precio unitario de compra = precio total / unidades.
-- Ganancia = precio de venta - precio unitario de compra; ganancia_pct = ganancia / precio unitario de compra x 100.
-- Stock = lo que entró por inventario - lo que salió por ventas.
CREATE VIEW v_productos AS
  SELECT b.*, (b.precio_venta - b.precio_compra) AS ganancia,
         CASE WHEN b.precio_compra > 0 THEN ROUND((b.precio_venta - b.precio_compra) / b.precio_compra * 100, 1) END AS ganancia_pct
  FROM (
    SELECT p.id, p.codigo, p.nombre, p.categoria_id, c.nombre AS categoria,
           p.precio_total_compra, p.unidades_compra,
           COALESCE(ROUND(p.precio_total_compra / NULLIF(p.unidades_compra, 0), 2), 0) AS precio_compra,
           p.precio_venta, p.stock_minimo,
           (COALESCE((SELECT SUM(m.cantidad) FROM inventario_movimientos m WHERE m.producto_id = p.id), 0)
            - COALESCE((SELECT SUM(i.cantidad) FROM venta_items i WHERE i.producto_id = p.id), 0))::int AS stock
    FROM productos p LEFT JOIN categorias c ON c.id = p.categoria_id
  ) b;

-- Precio unitario = precio total / unidades. "fecha" es la marca de tiempo del registro (se muestra en hora de Colombia)
CREATE VIEW v_inventario AS
  SELECT m.id, m.fecha, m.tipo, m.producto_id, m.proveedor_id, p.nombre AS producto, pr.empresa AS proveedor,
         COALESCE(NULLIF(m.lote, ''), 'L-' || m.id) AS lote,
         m.cantidad, m.precio_total,
         CASE WHEN m.cantidad > 0 THEN ROUND(m.precio_total / m.cantidad, 2) ELSE 0 END AS costo_unitario,
         m.fecha_vencimiento::text AS fecha_vencimiento
  FROM inventario_movimientos m
  JOIN productos p ON p.id = m.producto_id
  LEFT JOIN proveedores pr ON pr.id = m.proveedor_id;

-- Costo promedio de compra de cada producto según el INVENTARIO: suma de precios totales / suma de unidades (solo compras)
CREATE VIEW v_costo_inventario AS
  SELECT producto_id, ROUND(SUM(precio_total) / NULLIF(SUM(cantidad), 0), 2) AS costo_promedio
  FROM inventario_movimientos
  WHERE tipo = 'Compra' AND cantidad > 0
  GROUP BY producto_id;

-- Ganancia de la venta (solo para mostrar, no se guarda): (precio de venta - costo promedio del inventario) x cantidad.
-- ganancia_pct = ganancia / costo x 100. Si algún producto de la venta no tiene compras en inventario, queda vacía.
CREATE VIEW v_ventas AS
  SELECT v.id, v.fecha, v.cliente_id, c.nombre AS cliente, v.total, v.debe,
         COALESCE((SELECT SUM(i.cantidad) FROM venta_items i WHERE i.venta_id = v.id), 0)::int AS unidades,
         (SELECT string_agg(p.nombre || ' x' || i.cantidad, ', ' ORDER BY i.id)
          FROM venta_items i JOIN productos p ON p.id = i.producto_id WHERE i.venta_id = v.id) AS detalle,
         g.ganancia,
         CASE WHEN g.costo > 0 THEN ROUND(g.ganancia / g.costo * 100, 1) END AS ganancia_pct
  FROM ventas v
  LEFT JOIN clientes c ON c.id = v.cliente_id
  LEFT JOIN LATERAL (
    SELECT CASE WHEN bool_and(ci.costo_promedio IS NOT NULL) THEN SUM(i.cantidad * (i.precio_unitario - ci.costo_promedio)) END AS ganancia,
           CASE WHEN bool_and(ci.costo_promedio IS NOT NULL) THEN SUM(i.cantidad * ci.costo_promedio) END AS costo
    FROM venta_items i
    LEFT JOIN v_costo_inventario ci ON ci.producto_id = i.producto_id
    WHERE i.venta_id = v.id
  ) g ON true;

-- Total de cada línea = cantidad x precio de venta al público.
-- ganancia / costo_unitario = con el costo del producto al momento de la venta (lo usan Dashboard y Reportes).
-- costo_inventario / ganancia_inv = con el costo promedio del inventario (lo usa el módulo Ventas).
CREATE VIEW v_venta_items AS
  SELECT i.id, i.venta_id, v.fecha, c.nombre AS cliente, i.producto_id, p.nombre AS producto, i.cantidad,
         i.precio_unitario, i.costo_unitario,
         (i.cantidad * i.precio_unitario) AS subtotal,
         (i.cantidad * (i.precio_unitario - i.costo_unitario)) AS ganancia,
         COALESCE(NULLIF(mv.lote, ''), 'L-' || mv.id) AS lote,
         ci.costo_promedio AS costo_inventario,
         (i.cantidad * (i.precio_unitario - ci.costo_promedio)) AS ganancia_inv,
         CASE WHEN ci.costo_promedio > 0 THEN ROUND((i.precio_unitario - ci.costo_promedio) / ci.costo_promedio * 100, 1) END AS ganancia_inv_pct
  FROM venta_items i
  JOIN ventas v ON v.id = i.venta_id
  JOIN productos p ON p.id = i.producto_id
  LEFT JOIN clientes c ON c.id = v.cliente_id
  LEFT JOIN v_costo_inventario ci ON ci.producto_id = i.producto_id
  LEFT JOIN inventario_movimientos mv ON mv.id = i.movimiento_id;

-- Deuda del cliente = lo que debe en sus ventas - sus abonos
CREATE VIEW v_clientes AS
  SELECT c.id, c.nombre, c.telefono, c.correo, c.creado,
         (COALESCE((SELECT SUM(v.debe) FROM ventas v WHERE v.cliente_id = c.id), 0)
          - COALESCE((SELECT SUM(a.monto) FROM abonos a WHERE a.cliente_id = c.id), 0)) AS deuda
  FROM clientes c;

-- Unidades que quedan de cada lote (cada compra o ajuste positivo del inventario es un lote).
-- Lo vendido eligiendo lote se descuenta de ese lote; lo que no tiene lote (ventas viejas y ajustes negativos)
-- se descuenta primero del lote que vence antes. Un lote agotado tiene restante = 0.
CREATE VIEW v_lotes_stock AS
  WITH entradas AS (
    SELECT m.id, m.producto_id, m.lote, m.fecha, m.fecha_vencimiento, m.cantidad,
           m.cantidad - COALESCE((SELECT SUM(i.cantidad) FROM venta_items i WHERE i.movimiento_id = m.id), 0) AS base
    FROM inventario_movimientos m
    WHERE m.cantidad > 0
  ), acum AS (
    SELECT e.*, SUM(e.base) OVER (PARTITION BY e.producto_id
                                  ORDER BY e.fecha_vencimiento NULLS LAST, e.fecha, e.id) AS acumulado
    FROM entradas e
  ), salidas AS (
    SELECT p.id AS producto_id,
           COALESCE((SELECT SUM(i.cantidad) FROM venta_items i WHERE i.producto_id = p.id AND i.movimiento_id IS NULL), 0)
           + COALESCE((SELECT -SUM(m.cantidad) FROM inventario_movimientos m
                       WHERE m.producto_id = p.id AND m.cantidad < 0), 0) AS total
    FROM productos p
  )
  SELECT a.id, a.producto_id, COALESCE(NULLIF(a.lote, ''), 'L-' || a.id) AS lote,
         a.fecha_vencimiento::text AS fecha_vencimiento, a.cantidad AS cantidad_inicial,
         LEAST(a.base, GREATEST(0, a.acumulado - s.total))::int AS restante
  FROM acum a JOIN salidas s ON s.producto_id = a.producto_id;

-- Lotes con fecha de vencimiento y unidades que aún quedan (módulo "Por vencer").
-- Cuando un lote se agota deja de aparecer. dias_restantes negativo = ya vencido (fecha de Colombia).
CREATE VIEW v_lotes AS
  SELECT l.id, l.producto_id, p.nombre AS producto, c.nombre AS categoria, l.lote,
         l.fecha_vencimiento, l.cantidad_inicial, l.restante,
         (l.fecha_vencimiento::date - (now() AT TIME ZONE 'America/Bogota')::date) AS dias_restantes
  FROM v_lotes_stock l
  JOIN productos p ON p.id = l.producto_id
  LEFT JOIN categorias c ON c.id = p.categoria_id
  WHERE l.restante > 0 AND l.fecha_vencimiento IS NOT NULL;

CREATE VIEW v_abonos AS
  SELECT a.id, a.fecha, a.cliente_id, c.nombre AS cliente, a.monto
  FROM abonos a JOIN clientes c ON c.id = a.cliente_id;

-- 9) Verificación (opcional): ejecuta esto aparte; deben salir las 10 vistas y las llaves foráneas
-- SELECT table_name FROM information_schema.views WHERE table_schema = current_schema() ORDER BY 1;
-- SELECT conrelid::regclass AS tabla, conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE contype = 'f' ORDER BY 1;
