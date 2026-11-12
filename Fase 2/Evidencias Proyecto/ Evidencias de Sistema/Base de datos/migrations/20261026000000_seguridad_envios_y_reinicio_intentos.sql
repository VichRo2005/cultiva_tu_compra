-- Seguridad y trazabilidad de la iteracion de auditoria.
-- 1) Los triggers de proteccion comparaban current_setting(..., true) contra
--    'true' sin coalesce: si la GUC no esta definida el resultado es NULL y la
--    guardia completa se evalua NULL (= no protege). Un vendedor autenticado
--    podria escribir codigo_verificado_en / finanzas del pedido por API directa
--    sin ser bloqueado. La guardia ahora coalesce a 'false'.
-- 2) Limite de 3 postulaciones (RF-021): se conserva, y se agrega el mecanismo
--    administrativo para reiniciarlo con registro de quien, cuando y motivo.
begin;

-- ------------------------------------------------------------------
-- 1) Guardias de inmutabilidad con GUC opcional: NULL -> 'false'.
-- ------------------------------------------------------------------
create or replace function public.proteger_datos_criticos_envio()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
  v_operacion_interna boolean := coalesce(current_setting('cutuco.operacion_interna', true), 'false') = 'true';
begin
  v_jwt := current_setting('request.jwt.claims', true);

  if v_jwt is not null and pg_trigger_depth() = 1 and current_user <> 'service_role' and not v_operacion_interna then
    if new."pedido_id" is distinct from old."pedido_id"
       or new."repartidor_id" is distinct from old."repartidor_id"
       or new."tarifa_fija" is distinct from old."tarifa_fija" then
      raise exception 'Los datos estructurales del envio son inmutables desde la API directa';
    end if;

    if new."estado" = old."estado" then
      if new."codigo_verificacion" is distinct from old."codigo_verificacion"
         or new."codigo_verificado_en" is distinct from old."codigo_verificado_en"
         or new."despachado_en" is distinct from old."despachado_en"
         or new."entregado_en" is distinct from old."entregado_en"
         or new."fallido_en" is distinct from old."fallido_en"
         or new."motivo_fallo" is distinct from old."motivo_fallo" then
        raise exception 'La trazabilidad del envio solo puede cambiar mediante su maquina de estados o RPC autorizadas';
      end if;
    elsif new."codigo_verificado_en" is distinct from old."codigo_verificado_en" then
      raise exception 'El codigo de entrega solo puede verificarse mediante la RPC autorizada';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.proteger_campos_criticos_pedido()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_jwt text;
  v_operacion_interna boolean := coalesce(current_setting('cutuco.operacion_interna', true), 'false') = 'true';
begin
  v_jwt := current_setting('request.jwt.claims', true);

  if v_jwt is not null and pg_trigger_depth() = 1 and current_user <> 'service_role' and not v_operacion_interna then
    if new."cliente_id" is distinct from old."cliente_id"
       or new."productor_id" is distinct from old."productor_id"
       or new."region_entrega_id" is distinct from old."region_entrega_id"
       or new."comuna_entrega_id" is distinct from old."comuna_entrega_id"
       or new."nombre_destinatario" is distinct from old."nombre_destinatario"
       or new."telefono_destinatario" is distinct from old."telefono_destinatario"
       or new."direccion_entrega" is distinct from old."direccion_entrega"
       or new."referencia_entrega" is distinct from old."referencia_entrega"
       or new."subtotal_productos" is distinct from old."subtotal_productos"
       or new."tarifa_delivery" is distinct from old."tarifa_delivery"
       or new."porcentaje_fee_plataforma" is distinct from old."porcentaje_fee_plataforma"
       or new."monto_fee_plataforma" is distinct from old."monto_fee_plataforma"
       or new."total" is distinct from old."total" then
      raise exception 'Los datos de identidad, snapshot y finanzas del pedido son inmutables desde la API directa';
    end if;
  end if;

  return new;
end;
$$;

-- ------------------------------------------------------------------
-- 2) Limite de 3 postulaciones con reinicio administrativo auditado (RF-021).
-- ------------------------------------------------------------------
alter table public.postulaciones_vendedores
  add column if not exists intentos_extra integer not null default 0;
alter table public.postulaciones_vendedores
  add constraint ck_postulacion_intentos_extra check (intentos_extra >= 0);
comment on column public.postulaciones_vendedores.intentos_extra is
  'Intentos adicionales autorizados por administracion al reiniciar el limite de 3; el maximo efectivo es 3 + intentos_extra.';

create table if not exists public.postulaciones_reinicio_intentos (
  id uuid primary key default gen_random_uuid(),
  postulacion_id uuid not null references public.postulaciones_vendedores(id) on delete cascade,
  admin_id uuid not null references public.perfiles(id) on delete restrict,
  intentos_extra_anteriores integer not null,
  intentos_extra_nuevos integer not null,
  motivo varchar(1000) not null,
  creado_en timestamptz not null default now()
);
alter table public.postulaciones_reinicio_intentos enable row level security;
revoke all on public.postulaciones_reinicio_intentos from public, anon, authenticated, service_role;
grant select on public.postulaciones_reinicio_intentos to authenticated, service_role;
create policy reinicio_select_admin on public.postulaciones_reinicio_intentos
  for select to authenticated using (private.es_admin_actual());
comment on table public.postulaciones_reinicio_intentos is
  'Auditoria de los reinicios del limite de 3 postulaciones: admin responsable, motivo y valores antes/despues.';

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
    if new.intentos_extra <> 0 then
      raise exception 'Solo administracion puede autorizar intentos adicionales';
    end if;
    if exists (select 1 from public.postulaciones_vendedores where perfil_id = new.perfil_id) then
      raise exception 'Debe reutilizar su postulacion anterior para conservar las observaciones';
    end if;
  else
    if new.id is distinct from old.id or new.perfil_id is distinct from old.perfil_id
      or new.creado_en is distinct from old.creado_en or new.intento is distinct from old.intento then
      raise exception 'La identidad y el contador de intentos son inmutables';
    end if;
    if new.intentos_extra is distinct from old.intentos_extra and not v_backend then
      raise exception 'Solo administracion puede autorizar intentos adicionales';
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
        if new.intento > 3 + new.intentos_extra then
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

create or replace function public.reiniciar_intentos_postulacion(
  p_postulacion_id uuid,
  p_motivo text
) returns public.postulaciones_vendedores
language plpgsql security definer set search_path = '' as $$
declare
  v_admin uuid;
  v_resultado public.postulaciones_vendedores;
  v_anterior integer;
begin
  if auth.uid() is null or not private.es_admin_actual() then
    raise exception using errcode = '42501', message = 'Solo un administrador puede reiniciar los intentos';
  end if;
  if nullif(btrim(p_motivo), '') is null or length(btrim(p_motivo)) < 10 then
    raise exception 'El reinicio requiere un motivo de al menos 10 caracteres';
  end if;
  v_admin := auth.uid();
  select intentos_extra into v_anterior
    from public.postulaciones_vendedores
    where id = p_postulacion_id and estado = 'rechazada';
  if v_anterior is null then
    raise exception 'Solo se puede reiniciar una postulacion rechazada';
  end if;
  update public.postulaciones_vendedores
    set intentos_extra = intentos_extra + 3
    where id = p_postulacion_id and estado = 'rechazada'
    returning * into v_resultado;
  insert into public.postulaciones_reinicio_intentos
    (postulacion_id, admin_id, intentos_extra_anteriores, intentos_extra_nuevos, motivo)
  values (p_postulacion_id, v_admin, coalesce(v_anterior, 0), v_resultado.intentos_extra, btrim(p_motivo));
  return v_resultado;
end;
$$;
revoke all on function public.reiniciar_intentos_postulacion(uuid, text) from public, anon;
grant execute on function public.reiniciar_intentos_postulacion(uuid, text) to authenticated, service_role;

commit;
