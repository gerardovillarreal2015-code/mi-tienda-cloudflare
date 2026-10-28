-- =====================================================================
--  OPCIONAL · Corregir el costo de ventas YA registradas
--  Neon > SQL Editor.   No cambia la estructura, solo el dato "costo" de líneas de venta.
--
--  Las ventas nuevas ya guardan el costo del lote elegido. Las anteriores guardaron el costo que
--  había en ese momento (del producto o del último lote). Este script deja en las que tienen lote
--  el costo REAL de ese lote (precio total ÷ unidades del lote).
--  Las ventas sin lote asignado no se tocan.
-- =====================================================================

-- 1) PRIMERO revisa qué cambiaría (no modifica nada):
SELECT i.venta_id, p.nombre AS producto, COALESCE(NULLIF(m.lote, ''), 'L-' || m.id) AS lote,
       i.costo_unitario AS costo_guardado, ROUND(m.precio_total / m.cantidad, 2) AS costo_del_lote,
       i.precio_unitario AS precio_venta
FROM venta_items i
JOIN inventario_movimientos m ON m.id = i.movimiento_id AND m.cantidad > 0
JOIN productos p ON p.id = i.producto_id
WHERE i.costo_unitario IS DISTINCT FROM ROUND(m.precio_total / m.cantidad, 2)
ORDER BY i.venta_id;

-- 2) Si te parece bien, ejecuta esto (quita los dos guiones del inicio de cada línea):
-- UPDATE venta_items i
-- SET costo_unitario = ROUND(m.precio_total / m.cantidad, 2)
-- FROM inventario_movimientos m
-- WHERE i.movimiento_id = m.id AND m.cantidad > 0
--   AND i.costo_unitario IS DISTINCT FROM ROUND(m.precio_total / m.cantidad, 2);
