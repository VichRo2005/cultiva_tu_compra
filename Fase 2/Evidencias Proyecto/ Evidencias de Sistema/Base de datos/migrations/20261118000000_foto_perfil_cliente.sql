-- Foto de perfil del cliente.
--
-- La ruta se guarda en `perfiles.foto_perfil_storage_path`. Cada persona
-- autenticada sólo puede escribir dentro de su propia carpeta {perfil_id}/.

begin;

alter table public."perfiles"
  add column if not exists "foto_perfil_storage_path" varchar(500);

-- Bucket público de avatares. La escritura y el listado por API quedan
-- estrictamente limitados a la carpeta del usuario autenticado.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'client-avatars',
  'client-avatars',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "client_avatars_select_propietario" on storage.objects;
create policy "client_avatars_select_propietario"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'client-avatars'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );

drop policy if exists "client_avatars_insert_propietario" on storage.objects;
create policy "client_avatars_insert_propietario"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'client-avatars'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );

drop policy if exists "client_avatars_update_propietario" on storage.objects;
create policy "client_avatars_update_propietario"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'client-avatars'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  )
  with check (
    bucket_id = 'client-avatars'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );

drop policy if exists "client_avatars_delete_propietario" on storage.objects;
create policy "client_avatars_delete_propietario"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'client-avatars'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );

commit;
