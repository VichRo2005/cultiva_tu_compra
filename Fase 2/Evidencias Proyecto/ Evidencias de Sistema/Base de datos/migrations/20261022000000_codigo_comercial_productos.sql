-- Codigo comercial de productos: identificador legible, unico y estable para
-- la interfaz y las comunicaciones. La clave primaria (uuid) no cambia; el
-- codigo vive aparte y se asigna una sola vez.
begin;

create sequence public.seq_codigo_producto start 1;

alter table public.productos
  add column codigo_producto varchar(24);

-- Backfill de registros existentes en orden de creacion.
update public.productos p
   set codigo_producto = 'PRD-' || lpad(nextval('public.seq_codigo_producto')::text, 6, '0')
  from (select id from public.productos order by creado_en, id) s
 where s.id = p.id
   and p.codigo_producto is null;

alter table public.productos
  alter column codigo_producto set not null,
  add constraint uq_producto_codigo_producto unique (codigo_producto);
comment on column public.productos.codigo_producto is
  'Codigo comercial estable (PRD-000001) para catalogo, vendedor y comunicaciones. No reemplaza al PK uuid.';
comment on sequence public.seq_codigo_producto is
  'Fuente de correlativo para codigo_producto; concurrente (nextval) sin colisiones.';

create function public.asignar_codigo_producto()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.codigo_producto is null or btrim(new.codigo_producto) = '' then
    new.codigo_producto := 'PRD-' || lpad(nextval('public.seq_codigo_producto')::text, 6, '0');
  end if;
  return new;
end;
$$;
revoke all on function public.asignar_codigo_producto() from public, anon, authenticated;
create trigger trg_asignar_codigo_producto
before insert on public.productos
for each row execute function public.asignar_codigo_producto();

commit;
