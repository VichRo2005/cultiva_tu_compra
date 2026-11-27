-- El número de operación identifica la transferencia que debe revisar
-- administración. Toda nueva transferencia debe registrarlo, incluso si se
-- invoca la RPC fuera de la interfaz del vendedor.
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
  if v_referencia = '' then
    raise exception 'El número de operación es obligatorio para registrar la transferencia';
  end if;

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

  if v_pago.token_ws is not null and v_pago.metodo = 'webpay' then
    raise exception 'Hay un pago Webpay pendiente de conciliación';
  end if;
  if length(v_referencia) > 80 or length(coalesce(p_observaciones, '')) > 1000 then
    raise exception 'La referencia admite hasta 80 caracteres y las observaciones hasta 1000';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_referencia, 0));
  if exists (
    select 1 from public.pagos_servicio
    where id <> v_pago.id and metodo = 'transferencia'
      and referencia = v_referencia and estado in ('pagado', 'pendiente_revision')
  ) then
    raise exception 'La referencia ya está registrada. Solicita revisión administrativa';
  end if;

  update public."pagos_servicio"
     set metodo = 'transferencia',
         referencia = v_referencia,
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

grant execute on function public.registrar_transferencia_servicio(text, text) to authenticated;

commit;
