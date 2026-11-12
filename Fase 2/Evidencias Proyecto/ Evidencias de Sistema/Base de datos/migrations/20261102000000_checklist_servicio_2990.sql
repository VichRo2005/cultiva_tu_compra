-- CK-0242: monto confirmado por el propietario el 2026-11-02.
-- Solo nuevas cuotas; conserva montos, referencias y fechas ya emitidos.
begin;
create or replace function private.crear_cuota_servicio(p_productor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_periodo date := date_trunc('month', (now() at time zone 'America/Santiago')::date)::date;
begin
  insert into public."pagos_servicio" (
    "productor_id", "periodo", "monto", "emitido_en", "vence_en"
  )
  values (p_productor_id, v_periodo, 2990, (now() at time zone 'America/Santiago')::date, (now() at time zone 'America/Santiago')::date + 10)
  on conflict ("productor_id", "periodo") do nothing;
end;
$$;

create or replace function public.mi_servicio()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_productor uuid;
begin
  select "id" into v_productor
  from public."productores"
  where "perfil_id" = auth.uid();
  if v_productor is null then
    return jsonb_build_object('estado', 'sin_productor');
  end if;

  perform private.crear_cuota_servicio(v_productor);
  perform private.sincronizar_morosidad_productor(v_productor);

  return jsonb_build_object(
    'productor_id', v_productor,
    'estado', private.estado_servicio(v_productor),
    'monto_mensual', 2990,
    'dias_vencimiento', 10,
    'dias_gracia', 5,
    'cuota', (
      select to_jsonb(c) from (
        select "id", "periodo", "monto", "emitido_en", "vence_en", "estado",
               "metodo", "referencia", "pagado_en", "observaciones"
        from public."pagos_servicio"
        where "productor_id" = v_productor
        order by "periodo" desc
        limit 1
      ) c
    ),
    'historial', coalesce((
      select jsonb_agg(to_jsonb(h) order by h."periodo" desc)
      from (
        select "id", "periodo", "monto", "emitido_en", "vence_en", "estado",
               "metodo", "referencia", "pagado_en", "observaciones"
        from public."pagos_servicio"
        where "productor_id" = v_productor
        order by "periodo" desc
        limit 24
      ) h
    ), '[]'::jsonb)
  );
end;
$$;


commit;
