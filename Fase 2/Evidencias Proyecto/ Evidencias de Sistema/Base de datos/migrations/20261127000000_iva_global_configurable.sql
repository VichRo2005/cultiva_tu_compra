-- Interruptor global del IVA: el estado se consulta públicamente para que el
-- carrito informe el mismo total que el checkout. Sólo los administradores
-- pueden modificar la fila singleton por la policy existente.
begin;

alter table public.configuracion_logistica
  add column if not exists iva_habilitado boolean not null default true,
  add column if not exists tasa_iva numeric(5,4) not null default 0.1900;

alter table public.configuracion_logistica
  drop constraint if exists ck_config_tasa_iva,
  add constraint ck_config_tasa_iva check (tasa_iva between 0 and 1);

update public.configuracion_logistica
   set iva_habilitado = coalesce(iva_habilitado, true),
       tasa_iva = coalesce(tasa_iva, 0.1900)
 where id = 1;

comment on column public.configuracion_logistica.iva_habilitado is
  'Define si los nuevos checkouts recargan IVA. No modifica snapshots de pedidos ya creados.';
comment on column public.configuracion_logistica.tasa_iva is
  'Tasa de IVA para nuevos checkouts cuando iva_habilitado es true.';

commit;
