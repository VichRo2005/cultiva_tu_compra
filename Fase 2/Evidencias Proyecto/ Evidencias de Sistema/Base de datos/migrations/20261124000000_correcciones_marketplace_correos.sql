-- Correcciones de publicación y notificaciones del marketplace.
--
-- 1) Cada decisión de postulación conserva si Brevo aceptó la notificación;
--    así una reintento posterior no duplica el correo.
-- 2) El precio por unidad no puede superar 999.999 CLP por ninguna vía.
-- 3) Reafirma los permisos y la policy de alta de productos para instalaciones
--    anteriores que no recibieron el grant/policy de la migración de alcance.

begin;

alter table public.postulaciones_revisiones
  add column if not exists correo_resolucion_enviado_en timestamptz;

comment on column public.postulaciones_revisiones.correo_resolucion_enviado_en is
  'Instante en que Brevo aceptó el correo de la decisión de este intento.';

alter table public.productos
  drop constraint if exists ck_producto_precio_maximo_cutuco,
  drop constraint if exists ck_producto_precio_maximo;

-- NOT VALID conserva publicaciones históricas que hubieran tenido un precio
-- superior, pero sí impone el límite en cada INSERT o UPDATE nuevo.
alter table public.productos
  add constraint ck_producto_precio_maximo
  check (precio <= 999999) not valid;

comment on constraint ck_producto_precio_maximo on public.productos is
  'Máximo comercial de 999.999 CLP por unidad en CuTuCo.';

create or replace function public.validar_limites_numericos_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.precio < 0 or new.precio > 999999 then
    raise exception 'El precio debe estar entre 0 y 999.999 CLP';
  end if;
  if new.stock < 0 or new.stock > 999999999.999 then
    raise exception 'El stock debe estar entre 0 y 999.999.999,999 unidades';
  end if;
  if new.stock_reservado < 0 or new.stock_reservado > 999999999.999 then
    raise exception 'El stock reservado debe estar entre 0 y 999.999.999,999 unidades';
  end if;
  return new;
end;
$$;

grant usage on schema private to authenticated;
grant execute on function private.es_productor_actual(uuid) to authenticated;
grant select, insert, update, delete on public.productos to authenticated;

drop policy if exists "productos_insert_vendedor" on public.productos;
create policy "productos_insert_vendedor"
  on public.productos for insert to authenticated
  with check (
    (select private.es_productor_actual(productor_id))
    and activo = true
    and eliminado_en is null
  );

-- Las observaciones son opcionales en cualquiera de las decisiones. Si el
-- administrador no deja una, el correo de resolución usa el texto automático
-- definido por el backend.
create or replace function public.resolver_postulacion_vendedor(
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
  if p_estado = 'aprobada' and nullif(btrim(p_codigo_comercio_mall), '') is null then
    raise exception 'La aprobacion requiere el codigo de comercio Mall de Transbank';
  end if;
  if nullif(btrim(p_observaciones), '') is not null
    and char_length(btrim(p_observaciones)) < 10 then
    raise exception 'Las observaciones deben tener entre 10 y 2500 caracteres';
  end if;
  if char_length(coalesce(p_observaciones, '')) > 2500 then
    raise exception 'Las observaciones no pueden exceder 2500 caracteres';
  end if;
  update public.postulaciones_vendedores
    set estado = p_estado, observaciones_admin = nullif(btrim(p_observaciones), ''),
        codigo_comercio_mall = nullif(btrim(p_codigo_comercio_mall), '')
    where id = p_postulacion_id and estado = 'en_revision' returning * into v_resultado;
  if not found then raise exception 'No existe una postulacion en revision con ese ID'; end if;
  return v_resultado;
end;
$$;
revoke all on function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text, text) from public, anon;
grant execute on function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text, text) to authenticated, service_role;

commit;
