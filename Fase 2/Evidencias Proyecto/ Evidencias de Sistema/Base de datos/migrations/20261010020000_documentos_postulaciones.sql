-- Documentos privados y reintentos conservando las revisiones previas.
begin;
alter type public.estado_postulacion_vendedor rename value 'pendiente_aprobacion' to 'en_revision';
create type public.tipo_persona as enum ('natural', 'juridica');
alter table public.postulaciones_vendedores
  alter column estado set default 'borrador',
  add column rut_solicitante varchar(12),
  add column tipo_de_persona public.tipo_persona,
  add column documento_identidad text,
  add column certificado_inicio_actividades_o_carnet_representante text,
  add column certificado_titularidad_bancaria text,
  add column comprobante_domicilio text,
  add column intento integer not null default 1 check (intento > 0),
  drop constraint ck_postulacion_revisada,
  add constraint ck_postulacion_revisada check (
    (estado in ('borrador', 'en_revision') and revisado_por is null and revisado_en is null)
    or (estado in ('aprobada', 'rechazada') and revisado_por is not null and revisado_en is not null)
  ),
  add constraint ck_postulacion_rut_formato check (rut_solicitante ~ '^[0-9]{7,8}-[0-9K]$');

drop index public.uq_postulacion_pendiente_por_perfil;
create unique index uq_postulacion_abierta_por_perfil
  on public.postulaciones_vendedores(perfil_id) where estado in ('borrador', 'en_revision');

create table public.postulaciones_revisiones (
  id uuid primary key default gen_random_uuid(),
  postulacion_id uuid not null references public.postulaciones_vendedores(id) on delete restrict,
  intento integer not null,
  estado public.estado_postulacion_vendedor not null check (estado in ('aprobada', 'rechazada')),
  observaciones_admin varchar(2500),
  revisado_por uuid references public.perfiles(id) on delete set null,
  revisado_en timestamptz not null,
  solicitud jsonb not null,
  unique (postulacion_id, intento)
);
insert into public.postulaciones_revisiones
  (postulacion_id, intento, estado, observaciones_admin, revisado_por, revisado_en, solicitud)
select id, intento, estado, observaciones_admin, revisado_por, revisado_en, to_jsonb(p)
from public.postulaciones_vendedores p where estado in ('aprobada', 'rechazada');
alter table public.postulaciones_revisiones enable row level security;
revoke all on public.postulaciones_revisiones from public, anon, authenticated, service_role;
grant select on public.postulaciones_revisiones to authenticated, service_role;
create policy revisiones_select_participantes on public.postulaciones_revisiones
  for select to authenticated using (private.puede_acceder_postulacion(postulacion_id));

-- Las rutas son localizadores estables del bucket privado. No persistir URLs
-- publicas ni URLs firmadas que expiran. Resolver con download/createSignedUrl.
create function private.ruta_documento_valida(p_ruta text, p_perfil uuid)
returns boolean language sql immutable set search_path = '' as $$
  select coalesce(p_ruta ~ ('^vendedor-documentos/' || p_perfil::text || '/[A-Za-z0-9_-]+\.(pdf|jpg|jpeg|png)$'), false);
$$;
grant execute on function private.ruta_documento_valida(text, uuid) to authenticated, service_role;
revoke all on function private.ruta_documento_valida(text, uuid) from public, anon;

create or replace function public.validar_postulacion_estado()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_backend boolean := current_user in ('postgres', 'service_role');
  v_resolviendo boolean := false;
  v_ruta text;
begin
  -- Mismo bloqueo que Storage: serializa envio/reintento con escrituras de archivos.
  perform 1 from public.perfiles where id = new.perfil_id for update;
  if tg_op = 'INSERT' then
    if new.estado <> 'borrador' or new.intento <> 1
      or new.observaciones_admin is not null or new.revisado_por is not null or new.revisado_en is not null then
      raise exception 'La postulacion debe comenzar como borrador sin revision';
    end if;
    if exists (select 1 from public.postulaciones_vendedores where perfil_id = new.perfil_id) then
      raise exception 'Debe reutilizar su postulacion anterior para conservar las observaciones';
    end if;
  else
    if new.id is distinct from old.id or new.perfil_id is distinct from old.perfil_id
      or new.creado_en is distinct from old.creado_en or new.intento is distinct from old.intento then
      raise exception 'La identidad y el contador de intentos son inmutables';
    end if;
    v_resolviendo := v_backend and private.es_admin_actual() and auth.uid() is not null
      and old.estado = 'en_revision' and new.estado in ('aprobada', 'rechazada');
    if v_resolviendo then
      if (to_jsonb(new) - array['estado','observaciones_admin','revisado_por','revisado_en','actualizado_en'])
        is distinct from (to_jsonb(old) - array['estado','observaciones_admin','revisado_por','revisado_en','actualizado_en']) then
        raise exception 'El administrador solo puede resolver y observar la solicitud';
      end if;
      new.revisado_por := auth.uid();
      new.revisado_en := now();
    else
      if old.estado not in ('borrador', 'rechazada')
        or new.estado not in (old.estado, 'en_revision') then
        raise exception 'Solo se puede editar o enviar un borrador o una postulacion rechazada';
      end if;
      if new.observaciones_admin is distinct from old.observaciones_admin
        or new.revisado_por is distinct from old.revisado_por or new.revisado_en is distinct from old.revisado_en then
        raise exception 'El solicitante no puede cambiar las observaciones ni la revision';
      end if;
      if old.estado = 'rechazada' and new.estado = 'en_revision' then
        new.intento := old.intento + 1;
        new.revisado_por := null;
        new.revisado_en := null;
        -- observaciones_admin conserva el ultimo comentario hasta la nueva decision.
      end if;
    end if;
  end if;
  if not v_resolviendo and not exists (
    select 1 from public.perfiles where id = new.perfil_id and rol = 'cliente' and activo and eliminado_en is null
  ) then
    raise exception 'Solo una cuenta cliente activa puede postular';
  end if;
  foreach v_ruta in array array[new.documento_identidad,
    new.certificado_inicio_actividades_o_carnet_representante,
    new.certificado_titularidad_bancaria, new.comprobante_domicilio]
  loop
    if v_ruta is not null and not private.ruta_documento_valida(v_ruta, new.perfil_id) then
      raise exception 'Documento fuera de la carpeta del solicitante o con formato no permitido';
    end if;
  end loop;
  if new.estado in ('en_revision', 'aprobada') and (
    new.rut_solicitante is null or new.tipo_de_persona is null or new.documento_identidad is null
    or new.certificado_inicio_actividades_o_carnet_representante is null
    or new.certificado_titularidad_bancaria is null or new.comprobante_domicilio is null
  ) then
    raise exception 'Complete RUT, tipo de persona y los cuatro documentos antes de enviar o aprobar';
  end if;
  return new;
end;
$$;
drop trigger trg_validar_estado_postulacion on public.postulaciones_vendedores;
create trigger trg_validar_estado_postulacion before insert or update on public.postulaciones_vendedores
  for each row execute function public.validar_postulacion_estado();

create function private.archivar_revision_postulacion()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.estado in ('aprobada', 'rechazada') and new.estado is distinct from old.estado then
    insert into public.postulaciones_revisiones
      (postulacion_id, intento, estado, observaciones_admin, revisado_por, revisado_en, solicitud)
    values (new.id, new.intento, new.estado, new.observaciones_admin, new.revisado_por, new.revisado_en, to_jsonb(new));
  end if;
  return new;
end;
$$;
create trigger trg_archivar_revision_postulacion after update on public.postulaciones_vendedores
  for each row execute function private.archivar_revision_postulacion();
revoke all on function private.archivar_revision_postulacion() from public, anon, authenticated;

drop policy postulaciones_insert_cliente on public.postulaciones_vendedores;
drop policy postulaciones_update_propias_admin on public.postulaciones_vendedores;
drop policy postulaciones_delete_admin on public.postulaciones_vendedores;
create policy postulaciones_insert_borrador on public.postulaciones_vendedores
  for insert to authenticated with check (perfil_id = auth.uid() and estado = 'borrador' and not private.es_admin_actual());
create policy postulaciones_update_borrador_rechazada on public.postulaciones_vendedores
  for update to authenticated using (
    perfil_id = auth.uid() and estado in ('borrador', 'rechazada') and not private.es_admin_actual()
  ) with check (perfil_id = auth.uid() and estado in ('borrador', 'rechazada', 'en_revision'));
create policy postulaciones_delete_borrador on public.postulaciones_vendedores
  for delete to authenticated using (perfil_id = auth.uid() and estado = 'borrador' and not private.es_admin_actual());

create function public.resolver_postulacion_vendedor(
  p_postulacion_id uuid, p_estado public.estado_postulacion_vendedor, p_observaciones text default null
) returns public.postulaciones_vendedores
language plpgsql security definer set search_path = '' as $$
declare v_resultado public.postulaciones_vendedores;
begin
  if auth.uid() is null or not private.es_admin_actual() then
    raise exception using errcode = '42501', message = 'Solo un administrador puede resolver postulaciones';
  end if;
  if p_estado is null or p_estado not in ('aprobada', 'rechazada') then
    raise exception 'La resolucion debe ser aprobada o rechazada';
  end if;
  if p_estado = 'rechazada' and nullif(btrim(p_observaciones), '') is null then
    raise exception 'El rechazo requiere observaciones para el solicitante';
  end if;
  update public.postulaciones_vendedores set estado = p_estado, observaciones_admin = p_observaciones
    where id = p_postulacion_id and estado = 'en_revision' returning * into v_resultado;
  if not found then raise exception 'No existe una postulacion en revision con ese ID'; end if;
  return v_resultado;
end;
$$;
revoke all on function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text) from public, anon;
grant execute on function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text) to authenticated, service_role;

-- El alta copia la identidad aprobada; el comercio hijo lo asigna el backend/admin.
create or replace function public.activar_productor_aprobado()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.estado = 'aprobada' and old.estado is distinct from new.estado then
    if (select count(*) from public.direcciones where perfil_id = new.perfil_id and activo) <> 1 then
      raise exception 'La cuenta del vendedor debe tener exactamente una direccion activa antes de ser aprobada';
    end if;
    insert into public.productores (perfil_id, nombre_comercial, descripcion, rut_oficial, aprobado_en)
      values (new.perfil_id, new.nombre_comercial_solicitado, new.descripcion, new.rut_solicitante, new.revisado_en)
      on conflict (perfil_id) do update set nombre_comercial = excluded.nombre_comercial,
        descripcion = excluded.descripcion, rut_oficial = excluded.rut_oficial,
        activo = true, aprobado_en = excluded.aprobado_en;
    update public.perfiles set rol = 'vendedor', activo = true where id = new.perfil_id;
  end if;
  return new;
end;
$$;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('vendedor-documentos', 'vendedor-documentos', false, 10485760,
  array['application/pdf', 'image/jpeg', 'image/png'])
on conflict(id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create function private.puede_escribir_documento_vendedor(p_nombre text)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or private.es_admin_actual()
    or not private.ruta_documento_valida('vendedor-documentos/' || p_nombre, v_uid) then
    return false;
  end if;
  perform 1 from public.perfiles where id = v_uid and activo and eliminado_en is null and rol = 'cliente' for update;
  if not found then return false; end if;
  return not exists (select 1 from public.postulaciones_vendedores
    where perfil_id = v_uid and estado in ('en_revision', 'aprobada'));
end;
$$;
revoke all on function private.puede_escribir_documento_vendedor(text) from public, anon;
grant execute on function private.puede_escribir_documento_vendedor(text) to authenticated;
create policy vendedor_documentos_select on storage.objects for select to authenticated
  using (bucket_id = 'vendedor-documentos' and
    (private.es_admin_actual() or (storage.foldername(name))[1] = auth.uid()::text));
create policy vendedor_documentos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'vendedor-documentos' and private.puede_escribir_documento_vendedor(name));
create policy vendedor_documentos_update on storage.objects for update to authenticated
  using (bucket_id = 'vendedor-documentos' and private.puede_escribir_documento_vendedor(name))
  with check (bucket_id = 'vendedor-documentos' and private.puede_escribir_documento_vendedor(name));
create policy vendedor_documentos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'vendedor-documentos' and private.puede_escribir_documento_vendedor(name));

-- Restrictivas: otras policies permisivas nunca deben ampliar este bucket.
create policy vendedor_documentos_limite_select on storage.objects as restrictive for select to authenticated
  using (bucket_id <> 'vendedor-documentos' or
    (private.es_admin_actual() or (storage.foldername(name))[1] = auth.uid()::text));
create policy vendedor_documentos_limite_insert on storage.objects as restrictive for insert to authenticated
  with check (bucket_id <> 'vendedor-documentos' or private.puede_escribir_documento_vendedor(name));
create policy vendedor_documentos_limite_update on storage.objects as restrictive for update to authenticated
  using (bucket_id <> 'vendedor-documentos' or private.puede_escribir_documento_vendedor(name))
  with check (bucket_id <> 'vendedor-documentos' or private.puede_escribir_documento_vendedor(name));
create policy vendedor_documentos_limite_delete on storage.objects as restrictive for delete to authenticated
  using (bucket_id <> 'vendedor-documentos' or private.puede_escribir_documento_vendedor(name));
create policy vendedor_documentos_limite_anon on storage.objects as restrictive for all to anon
  using (bucket_id <> 'vendedor-documentos') with check (bucket_id <> 'vendedor-documentos');

comment on table public.postulaciones_vendedores is
  'Borrador editable -> en_revision -> aprobada/rechazada. Rechazada editable y reenviable a en_revision; revisiones anteriores se conservan.';
comment on table public.postulaciones_revisiones is
  'Historial inmutable para API de cada decision administrativa, con snapshot de la solicitud y observaciones.';
comment on column public.postulaciones_vendedores.documento_identidad is
  'Ruta privada vendedor-documentos/{perfil_id}/archivo.pdf (o jpg/png): cedula natural, e-RUT juridica. No URL publica.';
comment on column public.postulaciones_vendedores.certificado_inicio_actividades_o_carnet_representante is
  'Ruta privada al certificado de inicio de actividades o carnet del representante legal.';
commit;
