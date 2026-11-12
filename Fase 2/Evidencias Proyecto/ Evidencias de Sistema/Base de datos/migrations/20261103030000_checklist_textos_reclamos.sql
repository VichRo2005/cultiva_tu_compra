-- CK-0179/0397/0399: la escritura directa debe respetar campos obligatorios.
-- No modifica reclamos existentes ni agrega reglas sobre adjuntos o resoluciones.
create or replace function public.validar_textos_reclamo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if btrim(coalesce(new.motivo, '')) = '' then
    raise exception 'Selecciona el motivo del reclamo';
  end if;
  if btrim(coalesce(new.descripcion, '')) = '' then
    raise exception 'Describe lo que ocurrió con tu pedido';
  end if;
  if new.respuesta_productor is not null
     and btrim(new.respuesta_productor) = '' then
    raise exception 'Escribe una respuesta para el cliente';
  end if;
  return new;
end;
$$;

create trigger trg_validar_textos_reclamo
before insert or update of motivo, descripcion, respuesta_productor on public.reclamos
for each row execute function public.validar_textos_reclamo();
