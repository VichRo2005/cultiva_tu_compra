-- CK-0365/0371/0381: las validaciones de campos editables también se aplican
-- al escribir directamente por PostgREST, conservando el alta interna de Auth.
begin;
create function public.validar_datos_editables_perfil()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_telefono text;
begin
  if current_user <> 'authenticated' then
    return new;
  end if;
  if (tg_op = 'INSERT' or new.nombre is distinct from old.nombre)
     and nullif(btrim(coalesce(new.nombre, '')), '') is null then
    raise exception 'El nombre es obligatorio y no puede quedar vacío';
  end if;
  if (tg_op = 'INSERT' or new.apellido is distinct from old.apellido)
     and nullif(btrim(coalesce(new.apellido, '')), '') is null then
    raise exception 'El apellido es obligatorio y no puede quedar vacío';
  end if;
  if tg_op = 'INSERT' or new.telefono is distinct from old.telefono then
    -- Mismo formato vigente que normalizarTelefonoChileno del frontend.
    v_telefono := regexp_replace(coalesce(new.telefono, ''), '[[:space:]().-]', '', 'g');
    if left(v_telefono, 3) = '+56' then
      v_telefono := substr(v_telefono, 4);
    elsif left(v_telefono, 2) = '56' and length(v_telefono) > 9 then
      v_telefono := substr(v_telefono, 3);
    end if;
    if v_telefono !~ '^(9[0-9]{8}|[23][0-9]{7,8})$' then
      raise exception 'Ingresa un teléfono chileno válido con prefijo +56';
    end if;
    new.telefono := '+56' || v_telefono;
  end if;
  return new;
end;
$$;
create trigger trg_validar_datos_editables_perfil
before insert or update of nombre, apellido, telefono on public.perfiles
for each row execute function public.validar_datos_editables_perfil();
revoke all on function public.validar_datos_editables_perfil() from public, anon, authenticated;

create function public.validar_nombre_producto()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if nullif(btrim(coalesce(new.nombre, '')), '') is null then
    raise exception 'El nombre del producto es obligatorio y no puede quedar vacío';
  end if;
  return new;
end;
$$;
create trigger trg_validar_nombre_producto
before insert or update of nombre on public.productos
for each row execute function public.validar_nombre_producto();
revoke all on function public.validar_nombre_producto() from public, anon, authenticated;
commit;
