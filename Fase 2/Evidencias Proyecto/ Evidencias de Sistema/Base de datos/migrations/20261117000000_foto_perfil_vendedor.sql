-- Foto de perfil del vendedor.
--
-- Se guarda la ruta dentro del bucket público `seller-avatars` en
-- `productores.foto_perfil_storage_path`. El vendedor dueño puede subir,
-- reemplazar y quitar su propia foto (la carpeta raíz del objeto es su
-- productor_id); cualquier visitante puede leerla.

begin;

alter table public."productores"
  add column if not exists "foto_perfil_storage_path" varchar(500);

-- Bucket público para avatares de vendedor (5 MiB, solo imágenes).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'seller-avatars',
  'seller-avatars',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- Lectura pública de los avatares.
drop policy if exists "seller_avatars_select_public" on storage.objects;
create policy "seller_avatars_select_public"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'seller-avatars');

-- El dueño del perfil escribe sólo dentro de su carpeta {productor_id}/.
drop policy if exists "seller_avatars_insert_vendedor" on storage.objects;
create policy "seller_avatars_insert_vendedor"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'seller-avatars'
    and (select private.es_productor_actual((string_to_array(name, '/'))[1]::uuid))
  );

drop policy if exists "seller_avatars_update_vendedor" on storage.objects;
create policy "seller_avatars_update_vendedor"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'seller-avatars'
    and (select private.es_productor_actual((string_to_array(name, '/'))[1]::uuid))
  )
  with check (
    bucket_id = 'seller-avatars'
    and (select private.es_productor_actual((string_to_array(name, '/'))[1]::uuid))
  );

drop policy if exists "seller_avatars_delete_vendedor" on storage.objects;
create policy "seller_avatars_delete_vendedor"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'seller-avatars'
    and (select private.es_productor_actual((string_to_array(name, '/'))[1]::uuid))
  );

commit;