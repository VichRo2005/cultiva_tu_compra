-- Foto de perfil y portada de tienda (RF-021, alcance vigente).
--
--   * `perfiles.foto_url`     → ruta en el bucket `perfil-imagenes` bajo
--     `avatars/<perfil_id>/<archivo>`; NULL significa "sin foto subida" y la UI
--     muestra el avatar generado con iniciales.
--   * `productores.portada_url` → ruta en el mismo bucket bajo
--     `portadas/<productor_id>/<archivo>`; NULL muestra la ilustración de
--     portada por defecto.
--
-- El bucket es público (sólo lectura anónima) porque la foto del vendedor se
-- muestra en su ficha pública; la escritura se controla con RLS sobre
-- `storage.objects`: cada usuario autenticado administra sólo su carpeta
-- `avatars/<su uid>` y el productor administra `portadas/<su productor_id>`
-- (misma función `private.es_productor_actual` que usa `product-images`).
--
-- Las políticas de fila de `perfiles`/`productores` ya permiten al propietario
-- actualizar sus columnas (sin restricción de columnas sobre estas tablas),
-- así que no se tocan políticas de tabla.
--
-- La RPC pública `perfil_publico_productor` gana la columna `foto_url` para
-- que la ficha pública del vendedor muestre su foto (se recrea porque
-- PostgreSQL no permite cambiar el tipo de retorno con CREATE OR REPLACE).

begin;

-- ------------------------------------------------------------------
-- 1) Columnas nuevas
-- ------------------------------------------------------------------
alter table public."perfiles"
  add column if not exists "foto_url" text;

alter table public."productores"
  add column if not exists "portada_url" text;

comment on column public."perfiles"."foto_url" is
  'Ruta en el bucket perfil-imagenes (avatars/<perfil_id>/<archivo>) de la foto de perfil; NULL = avatar generado con iniciales.';
comment on column public."productores"."portada_url" is
  'Ruta en el bucket perfil-imagenes (portadas/<productor_id>/<archivo>) de la portada de la tienda; NULL = ilustración por defecto.';

-- ------------------------------------------------------------------
-- 2) Bucket público de imágenes de perfil y portadas
-- ------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('perfil-imagenes', 'perfil-imagenes', true)
on conflict (id) do update
set name = excluded.name,
    public = excluded.public;

create policy "storage_perfil_imagenes_select_public"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'perfil-imagenes');

create policy "storage_perfil_imagenes_insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'perfil-imagenes'
    and (
      (select private.es_admin_actual())
      or (
        (storage.foldername(name))[1] = 'avatars'
        and (storage.foldername(name))[2]::uuid = (select auth.uid())
      )
      or (
        (storage.foldername(name))[1] = 'portadas'
        and (select private.es_productor_actual((storage.foldername(name))[2]::uuid))
      )
    )
  );

create policy "storage_perfil_imagenes_update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'perfil-imagenes'
    and (
      (select private.es_admin_actual())
      or (
        (storage.foldername(name))[1] = 'avatars'
        and (storage.foldername(name))[2]::uuid = (select auth.uid())
      )
      or (
        (storage.foldername(name))[1] = 'portadas'
        and (select private.es_productor_actual((storage.foldername(name))[2]::uuid))
      )
    )
  )
  with check (
    bucket_id = 'perfil-imagenes'
    and (
      (select private.es_admin_actual())
      or (
        (storage.foldername(name))[1] = 'avatars'
        and (storage.foldername(name))[2]::uuid = (select auth.uid())
      )
      or (
        (storage.foldername(name))[1] = 'portadas'
        and (select private.es_productor_actual((storage.foldername(name))[2]::uuid))
      )
    )
  );

create policy "storage_perfil_imagenes_delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'perfil-imagenes'
    and (
      (select private.es_admin_actual())
      or (
        (storage.foldername(name))[1] = 'avatars'
        and (storage.foldername(name))[2]::uuid = (select auth.uid())
      )
      or (
        (storage.foldername(name))[1] = 'portadas'
        and (select private.es_productor_actual((storage.foldername(name))[2]::uuid))
      )
    )
  );

-- ------------------------------------------------------------------
-- 3) La ficha pública del vendedor expone la foto de perfil
-- ------------------------------------------------------------------
drop function if exists public.perfil_publico_productor(uuid);

create or replace function public.perfil_publico_productor(p_productor_id uuid)
returns table (
  id uuid,
  nombre varchar,
  apellido varchar,
  telefono varchar,
  creado_en timestamptz,
  foto_url text
)
language sql
stable
security definer
set search_path = ''
as $$
  select p."id", p."nombre", p."apellido", p."telefono", p."creado_en", p."foto_url"
  from public."productores" pr
  join public."perfiles" p on p."id" = pr."perfil_id"
  where pr."id" = p_productor_id
    and pr."activo" = true
    and p."eliminado_en" is null
  limit 1;
$$;

comment on function public.perfil_publico_productor(uuid) is
  'HAL-CLI-005/006: campos públicos del perfil de un productor activo, incluida la foto de perfil (ruta en perfil-imagenes), sin datos internos.';

revoke all on function public.perfil_publico_productor(uuid) from public;
grant execute on function public.perfil_publico_productor(uuid) to anon, authenticated, service_role;

commit;
