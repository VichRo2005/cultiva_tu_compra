-- CK-0250/0257/0259/0261/0273: pago requiere evidencia bancaria o revisión admin.
-- No cambia pagos históricos ni elimina registros.
begin;
create or replace function public.registrar_transferencia_servicio(
  p_referencia text,
  p_observaciones text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_productor uuid;
  v_pago public."pagos_servicio"%rowtype;
  v_referencia text := btrim(coalesce(p_referencia, ''));
begin
  select id into v_productor from public."productores" where perfil_id = auth.uid();
  if v_productor is null then
    raise exception 'No tienes una tienda de productor activa';
  end if;

  perform private.crear_cuota_servicio(v_productor);
  select * into v_pago
    from public."pagos_servicio"
   where productor_id = v_productor
     and estado in ('pendiente', 'rechazado', 'pendiente_revision')
   order by periodo asc
   limit 1
   for update;
  if not found then
    raise exception 'No hay una cuota pendiente para pagar';
  end if;
  if v_pago.estado = 'pendiente_revision' then
    raise exception 'Tu transferencia ya está pendiente de revisión';
  end if;

  -- Una referencia escrita por el usuario no demuestra un abono bancario.
  if v_pago.token_ws is not null and v_pago.metodo = 'webpay' then
    raise exception 'Hay un pago Webpay pendiente de conciliación';
  end if;
  if length(v_referencia) > 80 or length(coalesce(p_observaciones, '')) > 1000 then
    raise exception 'La referencia admite hasta 80 caracteres y las observaciones hasta 1000';
  end if;
  -- Serializa referencias iguales incluso si pertenecen a cuotas distintas.
  if v_referencia <> '' then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_referencia, 0));
  end if;
  if v_referencia <> '' and exists (
    select 1 from public.pagos_servicio
    where id <> v_pago.id and metodo = 'transferencia'
      and referencia = v_referencia and estado in ('pagado', 'pendiente_revision')
  ) then
    raise exception 'La referencia ya está registrada. Solicita revisión administrativa';
  end if;

  update public."pagos_servicio"
     set metodo = 'transferencia',
         referencia = nullif(v_referencia, ''),
         observaciones = nullif(btrim(coalesce(p_observaciones, '')), ''),
         estado = 'pendiente_revision',
         pagado_en = null,
         revisado_por = null,
         revisado_en = null
   where id = v_pago.id;

  perform private.sincronizar_morosidad_productor(v_productor);

  return jsonb_build_object(
    'pago_id', v_pago.id,
    'estado', 'pendiente_revision',
    'automatico', false
  );
end;
$$;

-- ------------------------------------------------------------------
-- 7) Revisión administrativa
-- ------------------------------------------------------------------
create or replace function public.resolver_pago_servicio(
  p_pago_id uuid,
  p_estado text,
  p_observaciones text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pago public."pagos_servicio"%rowtype;
begin
  if not private.es_admin_actual() then
    raise exception 'Solo un administrador puede revisar pagos del servicio';
  end if;
  if p_estado is null or p_estado not in ('pagado', 'rechazado') then
    raise exception 'Resolución inválida';
  end if;

  if p_estado = 'rechazado' and nullif(btrim(coalesce(p_observaciones, '')), '') is null then
    raise exception 'El rechazo requiere observaciones';
  end if;
  if length(coalesce(p_observaciones, '')) > 1000 then
    raise exception 'Las observaciones admiten hasta 1000 caracteres';
  end if;
  select * into v_pago from public."pagos_servicio" where id = p_pago_id for update;
  if not found then
    raise exception 'Pago de servicio inexistente';
  end if;
  if v_pago.estado <> 'pendiente_revision' then
    raise exception 'El pago ya fue revisado o no requiere revisión';
  end if;

  update public."pagos_servicio"
     set estado = p_estado,
         observaciones = nullif(btrim(coalesce(p_observaciones, '')), ''),
         revisado_por = auth.uid(),
         revisado_en = now(),
         pagado_en = case when p_estado = 'pagado' then now() else null end
   where id = p_pago_id;

  if p_estado = 'pagado' then
    update public."productores"
       set servicio_suspendido = false, servicio_suspendido_en = null
     where id = v_pago.productor_id;
  end if;
  perform private.sincronizar_morosidad_productor(v_pago.productor_id);

  return jsonb_build_object('pago_id', p_pago_id, 'estado', p_estado);
end;
$$;

create or replace function private.estado_servicio(p_productor_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not exists (select 1 from public."productores" where id = p_productor_id) then 'sin_productor'
    when exists (
      select 1 from public."pagos_servicio"
      where productor_id = p_productor_id
        and estado in ('pendiente', 'rechazado', 'pendiente_revision')
        and vence_en + 5 < (now() at time zone 'America/Santiago')::date
    ) then 'vencido'
    when exists (
      select 1 from public."pagos_servicio"
      where productor_id = p_productor_id and estado = 'pendiente_revision'
    ) then 'pendiente_revision'
    when exists (
      select 1 from public."pagos_servicio"
      where productor_id = p_productor_id and estado in ('pendiente', 'rechazado', 'pendiente_revision')
    ) then 'pendiente'
    else 'al_dia'
  end;
$$;

create or replace function private.sincronizar_morosidad_productor(p_productor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_suspendido boolean;
begin
  select exists (
    select 1 from public."pagos_servicio"
    where productor_id = p_productor_id
      and estado in ('pendiente', 'rechazado', 'pendiente_revision')
      and vence_en + 5 < (now() at time zone 'America/Santiago')::date
  ) into v_suspendido;

  update public."productores"
     set servicio_suspendido = v_suspendido,
         servicio_suspendido_en = case
           when v_suspendido then coalesce(servicio_suspendido_en, now())
           else null
         end
   where id = p_productor_id;
end;
$$;


commit;
