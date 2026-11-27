-- Portada (imagen de fondo) de la tienda del vendedor.
--
-- Se guarda la ruta dentro del bucket público `store-covers` en
-- `productores.portada_storage_path`. El vendedor dueño puede subir,
-- reemplazar y quitar su propia portada (la carpeta raíz del objeto es su
-- productor_id); cualquier visitante puede leerla.

begin;

alter table public."productores"
  add column if not exists "portada_storage_path" varchar(500);

-- Bucket público para portadas de tienda (5 MiB, sólo imágenes).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'store-covers',
  'store-covers',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- Lectura pública de las portadas.
drop policy if exists "store_covers_select_public" on storage.objects;
create policy "store_covers_select_public"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'store-covers');

-- El dueño de la tienda escribe sólo dentro de su carpeta {productor_id}/.
drop policy if exists "store_covers_insert_vendedor" on storage.objects;
create policy "store_covers_insert_vendedor"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'store-covers'
    and (select private.es_productor_actual((string_to_array(name, '/'))[1]::uuid))
  );

drop policy if exists "store_covers_update_vendedor" on storage.objects;
create policy "store_covers_update_vendedor"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'store-covers'
    and (select private.es_productor_actual((string_to_array(name, '/'))[1]::uuid))
  )
  with check (
    bucket_id = 'store-covers'
    and (select private.es_productor_actual((string_to_array(name, '/'))[1]::uuid))
  );

drop policy if exists "store_covers_delete_vendedor" on storage.objects;
create policy "store_covers_delete_vendedor"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'store-covers'
    and (select private.es_productor_actual((string_to_array(name, '/'))[1]::uuid))
  );

commit;
