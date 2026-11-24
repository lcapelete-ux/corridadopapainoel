-- CORREÇÃO: inscrições entram, mas o admin não vê a lista no painel.
-- Garante que quem está logado no painel pode LER as inscrições (e que o público continua só se inscrevendo).
-- Pode rodar de novo sem problema. Não apaga nada.

alter table public.registrations enable row level security;

grant select on public.registrations to authenticated;

drop policy if exists "admin ve inscricoes" on public.registrations;
create policy "admin ve inscricoes" on public.registrations
  for select to authenticated using (true);

-- Público: só consegue se inscrever (não lê, não altera, não apaga).
drop policy if exists "publico pode se inscrever" on public.registrations;
create policy "publico pode se inscrever" on public.registrations
  for insert to anon, authenticated with check (true);
