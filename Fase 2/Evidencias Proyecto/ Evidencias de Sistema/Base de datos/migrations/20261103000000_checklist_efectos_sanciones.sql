-- CK-0204/0216: una amonestación no bloquea ni reactiva una cuenta.
-- La deuda conserva su bandera independiente servicio_suspendido.
begin;
create or replace function public.aplicar_efecto_sancion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.estado = 'activa' and new.accion in ('suspender', 'ban_permanente') then
    update public.productores set activo = false where id = new.productor_id;
    if new.accion = 'ban_permanente' then
      update public.perfiles p set activo = false
      from public.productores pr
      where pr.id = new.productor_id and p.id = pr.perfil_id;
    end if;
  elsif new.estado in ('resuelta', 'cancelada', 'expirada')
        and new.accion = 'suspender' then
    if not exists (
      select 1 from public.sanciones s
      where s.productor_id = new.productor_id and s.id <> new.id
        and s.estado in ('activa', 'apelada')
        and s.accion in ('suspender', 'ban_permanente')
    ) then
      update public.productores pr set activo = true
      where pr.id = new.productor_id
        and exists (select 1 from public.perfiles p
                    where p.id = pr.perfil_id and p.activo and p.eliminado_en is null);
    end if;
  end if;
  return new;
end;
$$;
commit;
