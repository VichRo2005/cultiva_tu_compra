-- CK-0258: una transferencia de monto distinto (o cualquier resolución) no
-- puede marcar la cuota como pagada sin resolución registrada: el admin debe
-- dejar constancia del monto recibido y del beneficiario verificado.
-- No cambia pagos históricos ni elimina registros.
begin;

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

  -- CK-0258: toda resolución (incluido 'pagado') exige registrar el monto y
  -- el beneficiario verificados; sin constancia no se marca pagada.
  if nullif(btrim(coalesce(p_observaciones, '')), '') is null then
    raise exception 'La resolución requiere registrar el monto recibido y el beneficiario verificado';
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

commit;
