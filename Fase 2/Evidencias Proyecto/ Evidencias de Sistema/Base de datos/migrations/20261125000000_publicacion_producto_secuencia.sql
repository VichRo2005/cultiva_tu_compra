-- El código comercial se genera durante el INSERT de productos. La función
-- anterior se ejecutaba con permisos del vendedor y `nextval` sobre la
-- secuencia devolvía 42501, aunque la policy RLS autorizara la publicación.
--
-- Se mantiene la secuencia privada y se eleva únicamente el trigger, con un
-- search_path fijo; así los productores no reciben acceso directo a ella.

begin;

create or replace function public.asignar_codigo_producto()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.codigo_producto is null or btrim(new.codigo_producto) = '' then
    new.codigo_producto :=
      'PRD-' || lpad(nextval('public.seq_codigo_producto')::text, 6, '0');
  end if;
  return new;
end;
$$;

revoke all on function public.asignar_codigo_producto() from public, anon, authenticated;

comment on function public.asignar_codigo_producto() is
  'Asigna el código comercial del producto con privilegios acotados al trigger.';

commit;
