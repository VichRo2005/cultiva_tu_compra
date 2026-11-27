-- Código de entrega de seis dígitos, compartido por cliente y vendedor.
-- Los códigos históricos se regeneran para que la restricción pueda aplicarse
-- sin dejar valores de doce caracteres en pedidos ya cerrados.
begin;

create or replace function public.generar_codigo_verificacion()
returns varchar
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bytes bytea;
  v_numero bigint;
begin
  begin
    v_bytes := extensions.gen_random_bytes(4);
  exception when others then
    v_bytes := public.gen_random_bytes(4);
  end;

  v_numero :=
    (get_byte(v_bytes, 0)::bigint << 24) +
    (get_byte(v_bytes, 1)::bigint << 16) +
    (get_byte(v_bytes, 2)::bigint << 8) +
    get_byte(v_bytes, 3)::bigint;

  return lpad((v_numero % 1000000)::text, 6, '0');
end;
$$;

-- La actualización es una operación interna: mantiene la trazabilidad y no
-- permite que una llamada de cliente cambie el código directamente.
select set_config('cutuco.operacion_interna', 'true', true);

update public.envios
   set codigo_verificacion = public.generar_codigo_verificacion()
 where codigo_verificacion is not null
   and codigo_verificacion !~ '^[0-9]{6}$';

alter table public.envios
  alter column codigo_verificacion type varchar(6)
  using codigo_verificacion::varchar(6);

alter table public.envios
  add constraint ck_envio_codigo_verificacion_6_digitos
  check (codigo_verificacion is null or codigo_verificacion ~ '^[0-9]{6}$');

comment on column public.envios.codigo_verificacion is
  'Código aleatorio de entrega de seis dígitos, generado al iniciar el tránsito. Sólo el cliente lo ve y el vendedor lo confirma por RPC.';

commit;
