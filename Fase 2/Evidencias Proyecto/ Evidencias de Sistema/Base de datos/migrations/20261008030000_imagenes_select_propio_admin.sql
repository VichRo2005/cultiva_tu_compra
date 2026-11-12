-- ============================================================================
-- CuTuCo — El vendedor ve las imágenes de sus propios productos.
--
-- PROBLEMA QUE RESUELVE (reproducido contra la base local)
--   `imagenes_productos` tenía UNA sola policy de SELECT, la pública:
--
--     imagenes_productos_select_publico
--       using (exists (select 1 from public.productos p
--                      where p.id = producto_id
--                        and p.activo = true and p.eliminado_en is null))
--
--   Ese predicado exige que el PRODUCTO esté activo, así que al desactivar un
--   producto (RF-017 / r23 del mapeo: baja lógica con `activo = false`) sus
--   imágenes dejan de ser visibles incluso para su dueño. Verificado: con el
--   producto desactivado, la fila sigue en `productos` (1 fila visible) pero
--   `imagenes_productos` devuelve 0 filas al vendedor.
--
--   Consecuencias en la actividad «Vendedor / Productos»:
--     * r20 «Listar mis productos»: la tarjeta del producto desactivado pierde
--       su miniatura y aparece como si no tuviera fotos.
--     * r22 «Editar producto»: el formulario deduce «no tiene fotos» y exige
--       subir una nueva para poder guardar, dejando las anteriores inaccesibles
--       e imposibles de borrar desde la interfaz.
--
-- SOLUCIÓN
--   Policy de SELECT ADITIVA para el dueño del producto y el administrador,
--   siguiendo el mismo patrón que `productos_select_vendedor_admin`. El alcance
--   es exactamente el de la escritura ya existente
--   (`imagenes_productos_insert_vendedor_admin` usa el mismo helper), así que no
--   se amplía el acceso más allá de lo que el esquema ya permitía escribir. No se
--   elimina ni se modifica ninguna policy previa ni la lectura pública.
-- ============================================================================

create policy "imagenes_productos_select_propio_admin"
  on public."imagenes_productos" for select to authenticated
  using (
    (select private.es_productor_actual_de_producto("producto_id"))
    or (select private.es_admin_actual())
  );

comment on policy "imagenes_productos_select_propio_admin" on public."imagenes_productos" is
  'El productor dueño del producto (y el administrador) lee sus imágenes aunque el producto esté desactivado; la lectura pública sigue exigiendo producto activo (RF-003, RF-017).';
