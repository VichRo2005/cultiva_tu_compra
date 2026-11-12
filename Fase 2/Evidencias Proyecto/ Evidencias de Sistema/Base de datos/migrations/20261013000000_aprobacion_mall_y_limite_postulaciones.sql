-- Aprobacion con codigo de comercio Mall (Webpay Mall) y limite de 3 postulaciones.
-- Sandbox: los codigos de integracion se comparten, SIN restriccion UNIQUE.
begin;

-- a) La postulacion conserva el codigo de comercio Mall ingresado por el administrador.
alter table public.postulaciones_vendedores
  add column codigo_comercio_mall varchar(12),
  add constraint ck_postulacion_comercio_formato check (codigo_comercio_mall ~ '^[0-9]{12}$');
comment on column public.postulaciones_vendedores.codigo_comercio_mall is
  'Comercio hijo Webpay Mall asignado por administracion al resolver; se copia al productor al aprobar. Sandbox: no unico.';

-- b) Reenvio tras rechazo con maximo de 3 intentos; el admin puede asignar el
-- codigo de comercio Mall al resolver; el solicitante no puede tocarlo.
create or replace function public.validar_postulacion_estado()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_backend boolean := current_user in ('postgres', 'service_role');
  v_resolviendo boolean := false;
  v_ruta text;
begin
  perform 1 from public.perfiles where id = new.perfil_id for update;
  if tg_op = 'INSERT' then
    if new.estado <> 'borrador' or new.intento <> 1
      or new.observaciones_admin is not null or new.revisado_por is not null or new.revisado_en is not null then
      raise exception 'La postulacion debe comenzar como borrador sin revision';
    end if;
    if new.codigo_comercio_mall is not null then
      raise exception 'Solo administracion puede asignar el codigo de comercio Mall';
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
      if (to_jsonb(new) - array['estado','observaciones_admin','revisado_por','revisado_en','actualizado_en','codigo_comercio_mall'])
        is distinct from (to_jsonb(old) - array['estado','observaciones_admin','revisado_por','revisado_en','actualizado_en','codigo_comercio_mall']) then
        raise exception 'El administrador solo puede resolver y observar la solicitud';
      end if;
      new.revisado_por := auth.uid();
      new.revisado_en := now();
    else
      if new.codigo_comercio_mall is distinct from old.codigo_comercio_mall then
        raise exception 'Solo administracion puede asignar el codigo de comercio Mall';
      end if;
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
        if new.intento > 3 then
          raise exception 'Se alcanzo el maximo de 3 postulaciones permitidas';
        end if;
        new.revisado_por := null;
        new.revisado_en := null;
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

-- c) La aprobacion exige el codigo de comercio Mall y lo copia al productor.
create or replace function public.activar_productor_aprobado()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.estado = 'aprobada' and old.estado is distinct from new.estado then
    if new.codigo_comercio_mall is null then
      raise exception 'La aprobacion requiere el codigo de comercio Mall de Transbank';
    end if;
    if (select count(*) from public.direcciones where perfil_id = new.perfil_id and activo) <> 1 then
      raise exception 'La cuenta del vendedor debe tener exactamente una direccion activa antes de ser aprobada';
    end if;
    insert into public.productores (perfil_id, nombre_comercial, descripcion, rut_oficial, codigo_comercio_mall, aprobado_en)
      values (new.perfil_id, new.nombre_comercial_solicitado, new.descripcion, new.rut_solicitante,
        new.codigo_comercio_mall, new.revisado_en)
      on conflict (perfil_id) do update set nombre_comercial = excluded.nombre_comercial,
        descripcion = excluded.descripcion, rut_oficial = excluded.rut_oficial,
        codigo_comercio_mall = excluded.codigo_comercio_mall,
        activo = true, aprobado_en = excluded.aprobado_en;
    update public.perfiles set rol = 'vendedor', activo = true where id = new.perfil_id;
  end if;
  return new;
end;
$$;

-- d) El resolver administrativo recibe el codigo de comercio Mall al aprobar.
drop function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text);
create function public.resolver_postulacion_vendedor(
  p_postulacion_id uuid, p_estado public.estado_postulacion_vendedor,
  p_observaciones text default null, p_codigo_comercio_mall text default null
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
  if p_estado = 'aprobada' and nullif(btrim(p_codigo_comercio_mall), '') is null then
    raise exception 'La aprobacion requiere el codigo de comercio Mall de Transbank';
  end if;
  update public.postulaciones_vendedores
    set estado = p_estado, observaciones_admin = p_observaciones,
        codigo_comercio_mall = nullif(btrim(p_codigo_comercio_mall), '')
    where id = p_postulacion_id and estado = 'en_revision' returning * into v_resultado;
  if not found then raise exception 'No existe una postulacion en revision con ese ID'; end if;
  return v_resultado;
end;
$$;
revoke all on function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text, text) from public, anon;
grant execute on function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text, text) to authenticated, service_role;

commit;
