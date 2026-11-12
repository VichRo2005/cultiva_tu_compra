ALTER TABLE public.pedidos ADD COLUMN IF NOT EXISTS correo_comprador_enviado_en timestamptz;
ALTER TABLE public.pedidos ADD COLUMN IF NOT EXISTS correo_productor_enviado_en timestamptz;
