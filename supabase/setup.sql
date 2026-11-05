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
