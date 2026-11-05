-- CORRIDA DO PAPAI NOEL: configuração completa do Supabase
-- Cole tudo no SQL Editor e clique em Run. Pode rodar de novo sem problema.

-- Corrida do Papai Noel — configuração do banco (rodar uma vez no SQL Editor do Supabase)

-- 1) Tabela de inscrições
create table if not exists public.registrations (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  first_name  text not null,
  last_name   text not null,
  phone       text,
  email       text,
  file_url    text  -- link do comprovante de pagamento, ou 'ISENTO'
);

alter table public.registrations enable row level security;

-- Público pode SE INSCREVER, mas não pode ler, alterar nem apagar inscrições.
drop policy if exists "publico pode se inscrever" on public.registrations;
create policy "publico pode se inscrever"
  on public.registrations for insert
  to anon, authenticated
  with check (true);

-- 2) Pasta pública de fotos (galeria)
insert into storage.buckets (id, name, public)
values ('gallery', 'gallery', true)
on conflict (id) do update set public = true;

-- Público pode ver/listar as fotos da galeria (envio e exclusão só pelo painel do Supabase).
drop policy if exists "publico ve a galeria" on storage.objects;
create policy "publico ve a galeria"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'gallery');

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

-- Controle de inscrições (abrir/encerrar manual, por limite de inscritos e por data/hora)
-- Rodar UMA vez no SQL Editor do Supabase. Pode rodar de novo sem problema.
-- Requer que supabase/setup.sql (tabela registrations) já tenha sido executado.

-- 1) Campo de telefone/e-mail caso a tabela ainda não tenha
alter table public.registrations add column if not exists phone text;
alter table public.registrations add column if not exists email text;

-- 2) Configuração (uma linha só)
create table if not exists public.registration_settings (
  id               int primary key default 1 check (id = 1),
  manual_status    text not null default 'encerrada'
                   check (manual_status in ('aberta','encerrada','auto')),
  max_registrations int check (max_registrations is null or max_registrations > 0),
  opens_at         timestamptz,
  closes_at        timestamptz,
  price            numeric not null default 60,
  payment_info     text,
  allow_sober      boolean not null default true,
  updated_at       timestamptz not null default now()
);
alter table public.registration_settings add column if not exists allow_sober boolean not null default true;
insert into public.registration_settings (id) values (1) on conflict (id) do nothing;

alter table public.registration_settings enable row level security;

-- Só quem está logado no painel lê e altera a configuração.
drop policy if exists "admin le config" on public.registration_settings;
create policy "admin le config" on public.registration_settings
  for select to authenticated using (true);
drop policy if exists "admin altera config" on public.registration_settings;
create policy "admin altera config" on public.registration_settings
  for update to authenticated using (true) with check (id = 1);

-- 3) Status público das inscrições (aberta ou não, quantos inscritos, datas)
create or replace function public.inscricoes_status()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare s public.registration_settings; n int; ok boolean; why text;
begin
  select * into s from public.registration_settings where id = 1;
  select count(*) into n from public.registrations;
  if s.id is null then
    return jsonb_build_object('aberta', false, 'motivo', 'sem_config', 'total', n);
  end if;

  if s.max_registrations is not null and n >= s.max_registrations then
    ok := false; why := 'limite';
  elsif s.manual_status = 'encerrada' then
    ok := false; why := 'manual';
  elsif s.manual_status = 'aberta' then
    ok := true;  why := 'manual';
  elsif s.opens_at is null and s.closes_at is null then
    ok := false; why := 'sem_agenda';
  elsif s.opens_at is not null and now() < s.opens_at then
    ok := false; why := 'antes';
  elsif s.closes_at is not null and now() >= s.closes_at then
    ok := false; why := 'depois';
  else
    ok := true;  why := 'agenda';
  end if;

  return jsonb_build_object(
    'aberta', ok, 'motivo', why, 'modo', s.manual_status,
    'total', n, 'limite', s.max_registrations,
    'abre_em', s.opens_at, 'fecha_em', s.closes_at,
    'valor', s.price, 'pagamento', s.payment_info,
    'permite_isento', s.allow_sober);
end $$;

grant execute on function public.inscricoes_status() to anon, authenticated;

-- 4) Trava no servidor: impede inscrever fora do período ou acima do limite
create or replace function public.registrations_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform pg_advisory_xact_lock(7777);   -- evita passar do limite com cliques simultâneos
  if not coalesce((public.inscricoes_status() ->> 'aberta')::boolean, false) then
    raise exception 'Inscrições encerradas' using errcode = 'P0001';
  end if;
  if new.file_url = 'ISENTO'
     and not coalesce((public.inscricoes_status() ->> 'permite_isento')::boolean, true) then
    raise exception 'Inscrição sem cerveja não está disponível' using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists registrations_guard on public.registrations;
create trigger registrations_guard before insert on public.registrations
  for each row execute function public.registrations_guard();

-- Público pode se inscrever (a trava acima decide se está aberto)
drop policy if exists "publico pode se inscrever" on public.registrations;
create policy "publico pode se inscrever" on public.registrations
  for insert to anon, authenticated with check (true);

-- Quem está logado no painel vê as inscrições
drop policy if exists "admin ve inscricoes" on public.registrations;
create policy "admin ve inscricoes" on public.registrations
  for select to authenticated using (true);

-- 5) Pasta dos comprovantes de pagamento (até 5 MB, imagem ou PDF)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprovantes', 'comprovantes', true, 5242880,
        array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
on conflict (id) do update
  set public = true, file_size_limit = 5242880,
      allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic','application/pdf'];

drop policy if exists "publico envia comprovante" on storage.objects;
create policy "publico envia comprovante" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'comprovantes'
              and coalesce((public.inscricoes_status() ->> 'aberta')::boolean, false));
