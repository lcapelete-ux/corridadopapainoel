-- Expõe apenas a lista pública de lotes, sem abrir a tabela de configurações.
create or replace function public.inscricoes_lotes()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    (select price_lots from public.registration_settings where id = 1),
    '[]'::jsonb
  );
$$;
revoke all on function public.inscricoes_lotes() from public;
grant execute on function public.inscricoes_lotes() to anon, authenticated;
