REVOKE ALL ON public.datos_bancarios FROM anon, authenticated;
GRANT ALL ON public.datos_bancarios TO service_role;
DROP TRIGGER IF EXISTS trg_validar_datos_bancarios ON public.datos_bancarios;
DELETE FROM public.datos_bancarios WHERE numero_cuenta_cifrado = decode('DEADBEEF','hex');
