-- DIAGNÓSTICO (só leitura, não altera nada): por que o admin não vê as inscrições?
-- Cole no SQL Editor, clique em Run e leia o resultado (uma linha com um JSON).
select jsonb_build_object(
  'inscricoes_no_banco', (select count(*) from public.registrations),
  'rls_ligado',          (select relrowsecurity from pg_class where oid = 'public.registrations'::regclass),
  'politicas',           (select coalesce(jsonb_agg(jsonb_build_object('nome', policyname, 'comando', cmd, 'para', roles)), '[]'::jsonb)
                            from pg_policies where schemaname = 'public' and tablename = 'registrations'),
  'permissoes_authenticated', (select coalesce(jsonb_agg(privilege_type), '[]'::jsonb)
                            from information_schema.role_table_grants
                           where table_schema = 'public' and table_name = 'registrations' and grantee = 'authenticated'),
  'usuarios_do_painel',  (select coalesce(jsonb_agg(email), '[]'::jsonb) from auth.users),
  'ultimas_5_inscricoes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'quando', created_at, 'nome', first_name)), '[]'::jsonb)
                            from (select id, created_at, first_name from public.registrations order by created_at desc limit 5) x)
) as diagnostico;
