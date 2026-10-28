-- =====================================================================
--  MI TIENDA · DATOS DE PRUEBA (inventados)
--  Neon > SQL Editor > pegar todo > Run   (ejecutar DESPUÉS de migracion_final.sql)
--
--  • Se ejecuta una sola vez: si ya están, avisa y no repite nada.
--  • Las fechas son relativas a hoy y en hora de Colombia, así el dashboard
--    tiene ventas en el mes actual y en el anterior.
--  • Para borrar TODO (también tus datos reales) ve al final del archivo.
-- =====================================================================
DO $$
DECLARE
  s RECORD; v_id INT; v_cli INT; v_total NUMERIC; v_fecha TIMESTAMPTZ;
  v_hoy DATE := (now() AT TIME ZONE 'America/Bogota')::date;
BEGIN
  IF EXISTS (SELECT 1 FROM proveedores WHERE empresa = 'Licores del Sur S.A.S.') THEN
    RAISE NOTICE 'Los datos de prueba ya existen: no se agregó nada.';
    RETURN;
  END IF;

  -- Categorías (6)
  INSERT INTO categorias (nombre) VALUES ('Licores'),('Bebidas'),('Mecatos'),('Aseo'),('Otros'),('Lácteos')
    ON CONFLICT (nombre) DO NOTHING;

  -- Proveedores (6)
  INSERT INTO proveedores (empresa, contacto, telefono) VALUES
    ('Licores del Sur S.A.S.',   'Andrés Villota',  '310 555 0101'),
    ('Bebidas Nariño',           'Marcela Erazo',   '311 555 0102'),
    ('Mecatos Don Pepe',         'José Guerrero',   '312 555 0103'),
    ('Aseo y Hogar Ltda.',       'Patricia Bolaños','313 555 0104'),
    ('Lácteos La Victoria',      'Hernán Cabrera',  '314 555 0105'),
    ('Distribuidora La Esperanza','Sandra Muñoz',   '315 555 0106');

  -- Clientes (6)
  INSERT INTO clientes (nombre, telefono, correo) VALUES
    ('María Fernanda Rojas',   '300 555 0201', 'mfrojas@correo.com'),
    ('Carlos Andrés Mora',     '301 555 0202', 'camora@correo.com'),
    ('Tienda La Esquina',      '302 555 0203', 'laesquina@correo.com'),
    ('Luz Marina Ortiz',       '303 555 0204', 'lmortiz@correo.com'),
    ('Jhon Jairo Benavides',   '304 555 0205', 'jjbenavides@correo.com'),
    ('Rosa Elena Delgado',     '305 555 0206', 'redelgado@correo.com');

  -- Productos (6). El código (P-0001…) se genera solo.
  INSERT INTO productos (nombre, categoria_id, precio_total_compra, unidades_compra, precio_venta)
  SELECT x.nombre, c.id, x.total, x.unid, x.venta
  FROM (VALUES
    ('Aguardiente Nariño 750 ml', 'Licores', 912000, 24, 52000),
    ('Ron Medellín 375 ml',       'Licores', 600000, 24, 34000),
    ('Gaseosa Cola 1,5 L',        'Bebidas', 108000, 12, 12000),
    ('Papas Margarita 105 g',     'Mecatos',  96000, 48,  3000),
    ('Jabón Rey en barra',        'Aseo',     20000, 10,  3200),
    ('Leche entera 1 L',          'Lácteos',  72000, 24,  4200)
  ) AS x(nombre, cat, total, unid, venta)
  JOIN categorias c ON c.nombre = x.cat;

  -- Inventario: 6 compras con lote y vencimiento + 1 ajuste (merma). La gaseosa vence en 4 días y la leche ya venció.
  INSERT INTO inventario_movimientos (producto_id, proveedor_id, tipo, lote, cantidad, precio_total, fecha_vencimiento, fecha)
  SELECT p.id, pr.id, x.tipo, x.lote, x.cant, x.total, x.vence,
         ((date_trunc('day', now() AT TIME ZONE 'America/Bogota') - make_interval(days => x.dias)
           + make_interval(hours => x.h, mins => x.mi)) AT TIME ZONE 'America/Bogota')
  FROM (VALUES
    ('Aguardiente Nariño 750 ml','Licores del Sur S.A.S.','Compra','AG-2609', 24, 912000, v_hoy + 400, 45,  9, 10),
    ('Ron Medellín 375 ml',      'Licores del Sur S.A.S.','Compra','RM-2609', 24, 600000, v_hoy + 380, 44,  9, 40),
    ('Gaseosa Cola 1,5 L',       'Bebidas Nariño',        'Compra','GC-2610', 24, 216000, v_hoy + 4,   41, 11,  5),
    ('Papas Margarita 105 g',    'Mecatos Don Pepe',      'Compra','PM-2610', 48,  96000, v_hoy + 60,  40,  8, 30),
    ('Jabón Rey en barra',       'Aseo y Hogar Ltda.',    'Compra','JR-2609',  8,  16000, NULL::date,  39, 14, 15),
    ('Leche entera 1 L',         'Lácteos La Victoria',   'Compra','LE-2610', 24,  72000, v_hoy - 3,   38,  7, 50),
    ('Papas Margarita 105 g',    'Mecatos Don Pepe',      'Ajuste','PM-2610', -2,      0, NULL::date,  10, 16,  0)
  ) AS x(prod, prov, tipo, lote, cant, total, vence, dias, h, mi)
  JOIN productos p ON p.nombre = x.prod
  LEFT JOIN proveedores pr ON pr.empresa = x.prov;

  -- Ventas (6) con sus productos; lo que no se debe entra a caja
  FOR s IN SELECT j FROM jsonb_array_elements('[
    {"cli":"María Fernanda Rojas","d":35,"h":10,"mi":20,"debe":0,     "items":[{"p":"Aguardiente Nariño 750 ml","c":2},{"p":"Gaseosa Cola 1,5 L","c":2}]},
    {"cli":"Tienda La Esquina",    "d":28,"h":15,"mi":45,"debe":100000,"items":[{"p":"Ron Medellín 375 ml","c":6},{"p":"Papas Margarita 105 g","c":12}]},
    {"cli":"Carlos Andrés Mora",   "d":14,"h":9, "mi":15,"debe":15000, "items":[{"p":"Leche entera 1 L","c":6},{"p":"Jabón Rey en barra","c":5}]},
    {"cli":null,                   "d":9, "h":12,"mi":30,"debe":0,     "items":[{"p":"Gaseosa Cola 1,5 L","c":6},{"p":"Papas Margarita 105 g","c":10}]},
    {"cli":"Luz Marina Ortiz",     "d":4, "h":17,"mi":5, "debe":156000,"items":[{"p":"Aguardiente Nariño 750 ml","c":3}]},
    {"cli":"Jhon Jairo Benavides", "d":2, "h":11,"mi":40,"debe":52800, "items":[{"p":"Ron Medellín 375 ml","c":4},{"p":"Leche entera 1 L","c":4}]}
  ]'::jsonb) AS t(j) LOOP
    SELECT SUM(p.precio_venta * (it->>'c')::int) INTO v_total
      FROM jsonb_array_elements(s.j->'items') it JOIN v_productos p ON p.nombre = it->>'p';
    SELECT id INTO v_cli FROM clientes WHERE nombre = s.j->>'cli';
    v_fecha := (date_trunc('day', now() AT TIME ZONE 'America/Bogota') - make_interval(days => (s.j->>'d')::int)
                + make_interval(hours => (s.j->>'h')::int, mins => (s.j->>'mi')::int)) AT TIME ZONE 'America/Bogota';
    INSERT INTO ventas (cliente_id, total, debe, fecha)
      VALUES (v_cli, v_total, (s.j->>'debe')::numeric, v_fecha) RETURNING id INTO v_id;
    INSERT INTO venta_items (venta_id, producto_id, movimiento_id, cantidad, precio_unitario, costo_unitario)
      SELECT v_id, p.id,
             (SELECT m.id FROM inventario_movimientos m WHERE m.producto_id = p.id AND m.cantidad > 0 ORDER BY m.fecha LIMIT 1),
             (it->>'c')::int, p.precio_venta, p.precio_compra
      FROM jsonb_array_elements(s.j->'items') it JOIN v_productos p ON p.nombre = it->>'p';
    IF v_total - (s.j->>'debe')::numeric > 0 THEN
      INSERT INTO caja_movimientos (concepto, tipo, monto, venta_id, fecha)
        VALUES ('Venta #' || v_id, 'Ingreso', v_total - (s.j->>'debe')::numeric, v_id, v_fecha);
    END IF;
  END LOOP;

  -- Abonos (6) a las deudas; cada uno entra a caja
  FOR s IN SELECT j FROM jsonb_array_elements('[
    {"cli":"Tienda La Esquina",   "d":20,"h":10,"mi":0, "m":40000},
    {"cli":"Tienda La Esquina",   "d":8, "h":16,"mi":20,"m":30000},
    {"cli":"Carlos Andrés Mora",  "d":6, "h":9, "mi":45,"m":15000},
    {"cli":"Luz Marina Ortiz",    "d":3, "h":14,"mi":10,"m":50000},
    {"cli":"Luz Marina Ortiz",    "d":1, "h":10,"mi":35,"m":25000},
    {"cli":"Jhon Jairo Benavides","d":1, "h":15,"mi":25,"m":20000}
  ]'::jsonb) AS t(j) LOOP
    SELECT id INTO v_cli FROM clientes WHERE nombre = s.j->>'cli';
    v_fecha := (date_trunc('day', now() AT TIME ZONE 'America/Bogota') - make_interval(days => (s.j->>'d')::int)
                + make_interval(hours => (s.j->>'h')::int, mins => (s.j->>'mi')::int)) AT TIME ZONE 'America/Bogota';
    INSERT INTO abonos (cliente_id, monto, fecha) VALUES (v_cli, (s.j->>'m')::numeric, v_fecha) RETURNING id INTO v_id;
    INSERT INTO caja_movimientos (concepto, tipo, monto, abono_id, fecha)
      VALUES ('Abono de ' || (s.j->>'cli'), 'Ingreso', (s.j->>'m')::numeric, v_id, v_fecha);
  END LOOP;

  -- Caja: 6 movimientos manuales (además de los automáticos de ventas y abonos)
  INSERT INTO caja_movimientos (concepto, tipo, monto, fecha)
  SELECT x.concepto, x.tipo, x.monto,
         ((date_trunc('day', now() AT TIME ZONE 'America/Bogota') - make_interval(days => x.dias)
           + make_interval(hours => x.h, mins => x.mi)) AT TIME ZONE 'America/Bogota')
  FROM (VALUES
    ('Aporte inicial de caja',       'Ingreso', 500000, 44,  8,  0),
    ('Pago de arriendo del local',   'Egreso',  600000, 30,  9,  0),
    ('Pago de servicios públicos',   'Egreso',  120000, 20, 10, 30),
    ('Compra de bolsas y empaques',  'Egreso',   25000, 12, 11, 15),
    ('Pago de transporte',           'Egreso',   40000,  7, 13, 45),
    ('Ingreso por venta de reciclaje','Ingreso', 15000,  5, 15,  0)
  ) AS x(concepto, tipo, monto, dias, h, mi);

  RAISE NOTICE 'Datos de prueba agregados.';
END $$;

-- ---------------------------------------------------------------------
-- BORRAR TODO (¡elimina TODOS los datos, también los reales!). Descomenta solo si estás seguro.
-- TRUNCATE caja_movimientos, venta_items, abonos, ventas, inventario_movimientos, productos,
--          clientes, proveedores, categorias RESTART IDENTITY CASCADE;
-- ALTER SEQUENCE productos_codigo_seq RESTART;
-- INSERT INTO categorias (nombre) VALUES ('Licores'),('Bebidas'),('Mecatos'),('Aseo'),('Otros');
