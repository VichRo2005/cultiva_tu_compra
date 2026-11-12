-- Refuerzo de validación de direcciones de entrega.
--
-- La UI exige número de domicilio y valida la referencia. Esta migración
-- replica la regla en PostgreSQL para que no se pueda saltar escribiendo
-- directo por PostgREST. Se valida en INSERT y cuando el número cambia; las
-- filas legacy sin número pueden seguir actualizando otros campos (p. ej.
-- es_principal) sin quedar bloqueadas.

begin;

create or replace function public.validar_direccion_entrega()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_numero text := btrim(coalesce(new."numero", ''));
  v_referencia text := btrim(coalesce(new."referencia", ''));
begin
  if tg_op = 'INSERT' or new."numero" is distinct from old."numero" then
    if v_numero = '' or v_numero !~ '[0-9]' or length(v_numero) > 20 then
      raise exception 'El número de domicilio es obligatorio y debe incluir al menos un dígito';
    end if;
    if v_numero ~ '[[:cntrl:]]' then
      raise exception 'El número de domicilio contiene caracteres inválidos';
    end if;
  end if;

  if new."referencia" is not null then
    if length(v_referencia) < 4 or length(v_referencia) > 500 then
      raise exception 'La referencia debe tener entre 4 y 500 caracteres';
    end if;
    if v_referencia !~ '[[:alnum:]]' then
      raise exception 'La referencia debe contener letras o números';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists "trg_validar_direccion_entrega" on public."direcciones";
create trigger "trg_validar_direccion_entrega"
  before insert or update on public."direcciones"
  for each row execute function public.validar_direccion_entrega();

commit;
