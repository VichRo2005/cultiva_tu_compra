-- IVA de compras CuTuCo: el precio publicado y el despacho forman la base
-- imponible; se recarga IVA al cliente y se conserva el desglose inmutable por
-- pedido. Los pedidos históricos mantienen tasa y monto cero.
begin;

alter table public.pedidos
  add column if not exists tasa_iva numeric(5,4) not null default 0,
  add column if not exists monto_iva numeric(12,2) not null default 0;

comment on column public.pedidos.tasa_iva is
  'Tasa de IVA aplicada al pedido. Pedidos anteriores a esta migracion conservan 0.';
comment on column public.pedidos.monto_iva is
  'IVA recargado al cliente sobre subtotal de productos y despacho, redondeado a CLP entero.';

alter table public.pedidos
  add constraint ck_pedido_tasa_iva check (tasa_iva between 0 and 1) not valid,
  add constraint ck_pedido_monto_iva check (monto_iva >= 0) not valid,
  add constraint ck_pedido_iva_coherente check (
    monto_iva = round((subtotal_productos + tarifa_delivery) * tasa_iva, 0)
  ) not valid;

alter table public.pedidos drop constraint if exists ck_pedido_total_coherente;
alter table public.pedidos
  add constraint ck_pedido_total_coherente check (
    total = round(subtotal_productos + tarifa_delivery + monto_iva, 2)
  ) not valid;

alter table public.pedidos validate constraint ck_pedido_tasa_iva;
alter table public.pedidos validate constraint ck_pedido_monto_iva;
alter table public.pedidos validate constraint ck_pedido_iva_coherente;
alter table public.pedidos validate constraint ck_pedido_total_coherente;

-- Los detalles se insertan después del pedido. Este trigger conserva el IVA
-- del snapshot y evita que un cambio de ítems deje montos incoherentes.
create or replace function public.recalcular_totales_pedido(p_pedido_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_subtotal numeric(12,2);
  v_delivery numeric(12,2);
  v_porcentaje_fee numeric(5,4);
  v_tasa_iva numeric(5,4);
  v_fee numeric(12,2);
  v_iva numeric(12,2);
  v_total numeric(12,2);
begin
  select
    coalesce(sum(d.subtotal), 0),
    p.tarifa_delivery,
    p.porcentaje_fee_plataforma,
    p.tasa_iva
  into v_subtotal, v_delivery, v_porcentaje_fee, v_tasa_iva
  from public.pedidos p
  left join public.detalles_pedido d on d.pedido_id = p.id
  where p.id = p_pedido_id
  group by p.id, p.tarifa_delivery, p.porcentaje_fee_plataforma, p.tasa_iva;

  if not found then
    return;
  end if;

  v_fee := round(v_subtotal * v_porcentaje_fee, 2);
  v_iva := round((v_subtotal + v_delivery) * v_tasa_iva, 0);
  v_total := round(v_subtotal + v_delivery + v_iva, 2);

  update public.pedidos
     set subtotal_productos = v_subtotal,
         monto_fee_plataforma = v_fee,
         monto_iva = v_iva,
         total = v_total
   where id = p_pedido_id;
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
    if new.cliente_id is distinct from old.cliente_id
       or new.productor_id is distinct from old.productor_id
       or new.region_entrega_id is distinct from old.region_entrega_id
       or new.comuna_entrega_id is distinct from old.comuna_entrega_id
       or new.nombre_destinatario is distinct from old.nombre_destinatario
       or new.telefono_destinatario is distinct from old.telefono_destinatario
       or new.direccion_entrega is distinct from old.direccion_entrega
       or new.referencia_entrega is distinct from old.referencia_entrega
       or new.subtotal_productos is distinct from old.subtotal_productos
       or new.tarifa_delivery is distinct from old.tarifa_delivery
       or new.tasa_iva is distinct from old.tasa_iva
       or new.monto_iva is distinct from old.monto_iva
       or new.porcentaje_fee_plataforma is distinct from old.porcentaje_fee_plataforma
       or new.monto_fee_plataforma is distinct from old.monto_fee_plataforma
       or new.total is distinct from old.total then
      raise exception 'Los datos de identidad, snapshot y finanzas del pedido son inmutables desde la API directa';
    end if;
  end if;

  return new;
end;
$$;

commit;
