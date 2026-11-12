-- PostgreSQL concede EXECUTE a PUBLIC por defecto. Los GRANT por rol no revocan
-- ese permiso implícito, por lo que se cierra primero y se reabre sólo lo usado.
revoke execute on all functions in schema private from public;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as firma
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  loop
    execute format('revoke execute on function %s from public', f.firma);
  end loop;
end;
$$;

-- Predicados privados usados por RLS. No escriben datos.
grant execute on function private.es_admin_actual() to authenticated;
grant execute on function private.es_super_admin_actual() to authenticated;
grant execute on function private.es_productor_actual(uuid) to authenticated;
grant execute on function private.es_productor_actual_de_producto(uuid) to authenticated;
grant execute on function private.es_productor_propietario(uuid) to authenticated;
grant execute on function private.puede_acceder_datos_bancarios(uuid) to authenticated;
grant execute on function private.puede_acceder_envio(uuid) to authenticated;
grant execute on function private.puede_acceder_pedido(uuid) to authenticated;
grant execute on function private.puede_acceder_postulacion(uuid) to authenticated;
grant execute on function private.puede_escribir_documento_vendedor(text) to authenticated;
grant execute on function private.ruta_documento_valida(text, uuid) to authenticated;
grant execute on function private.productor_operable(uuid) to anon, authenticated;

-- RPC públicas de lectura.
grant execute on function public.perfil_publico_productor(uuid) to anon, authenticated, service_role;
grant execute on function public.evaluaciones_publicas_productor(uuid, integer) to anon, authenticated, service_role;
grant execute on function public.ubicaciones_publicas_productores(uuid[]) to anon, authenticated, service_role;

-- RPC autenticadas. Cada función conserva además sus controles de actor/rol.
grant execute on function public.actualizar_morosidad_servicio() to authenticated;
grant execute on function public.admin_servicio_resumen() to authenticated;
grant execute on function public.cancelar_pedido_vendedor(uuid, text) to authenticated, service_role;
grant execute on function public.confirmar_recepcion_pedido(uuid) to authenticated;
grant execute on function public.contiene_palabra_prohibida(text) to authenticated;
grant execute on function public.generar_codigo_verificacion() to authenticated, service_role;
grant execute on function public.marcar_pedido_en_preparacion(uuid) to authenticated, service_role;
grant execute on function public.mi_servicio() to authenticated;
grant execute on function public.obtener_codigo_entrega(uuid) to authenticated, service_role;
grant execute on function public.obtener_tarifa_delivery_defecto() to service_role;
grant execute on function public.registrar_transferencia_servicio(text, text) to authenticated;
grant execute on function public.reiniciar_intentos_postulacion(uuid, text) to authenticated, service_role;
grant execute on function public.resolver_pago_servicio(uuid, text, text) to authenticated;
grant execute on function public.resolver_postulacion_vendedor(uuid, public.estado_postulacion_vendedor, text, text) to authenticated, service_role;
grant execute on function public.verificar_codigo_entrega(uuid, text) to authenticated;
grant execute on function public.verificar_codigo_entrega_vendedor(uuid, text) to authenticated, service_role;
