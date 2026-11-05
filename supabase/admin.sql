-- Área restrita: permissões para quem está logado (marcelo, wilson, fernando).
-- Rodar UMA vez no SQL Editor do Supabase, depois de criar os 3 usuários em Authentication > Users.

-- Inscrições: logados podem ver; só o marcelo pode apagar.
drop policy if exists "admin ve inscricoes" on public.registrations;
create policy "admin ve inscricoes" on public.registrations
  for select to authenticated using (true);

drop policy if exists "marcelo apaga inscricoes" on public.registrations;
create policy "marcelo apaga inscricoes" on public.registrations
  for delete to authenticated
  using ((auth.jwt() ->> 'email') = 'marcelo@corridanoel.com');

-- Galeria: logados podem enviar e apagar fotos.
drop policy if exists "admin envia fotos" on storage.objects;
create policy "admin envia fotos" on storage.objects
  for insert to authenticated with check (bucket_id = 'gallery');

drop policy if exists "admin apaga fotos" on storage.objects;
create policy "admin apaga fotos" on storage.objects
  for delete to authenticated using (bucket_id = 'gallery');
