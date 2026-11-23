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

-- Confirmação de pagamento: o inscrito anexa o comprovante OU marca "já paguei" e o
-- admin confere na conta e marca como PAGO no painel.
-- Para quem JÁ rodou o tudo.sql antes. Pode rodar de novo sem problema.

-- 1) Colunas de pagamento
alter table public.registrations
  add column if not exists payment_status text not null default 'pendente'
    check (payment_status in ('pendente','pago','isento'));
alter table public.registrations add column if not exists paid_at timestamptz;
alter table public.registrations add column if not exists paid_by text;

-- inscrições antigas sem cerveja ficam como "isento"
update public.registrations set payment_status = 'isento' where file_url = 'ISENTO';

-- 2) Admin logado pode marcar pago/pendente. Só a coluna de status pode ser alterada.
revoke update on public.registrations from anon, authenticated;
grant update (payment_status) on public.registrations to authenticated;

drop policy if exists "admin confirma pagamento" on public.registrations;
create policy "admin confirma pagamento" on public.registrations
  for update to authenticated using (true) with check (true);

-- 3) Visitante nunca entra como "pago": o servidor define o status na inscrição
create or replace function public.registrations_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform pg_advisory_xact_lock(7777);
  if not coalesce((public.inscricoes_status() ->> 'aberta')::boolean, false) then
    raise exception 'Inscrições encerradas' using errcode = 'P0001';
  end if;
  if new.file_url = 'ISENTO'
     and not coalesce((public.inscricoes_status() ->> 'permite_isento')::boolean, true) then
    raise exception 'Inscrição sem cerveja não está disponível' using errcode = 'P0001';
  end if;
  new.payment_status := case when new.file_url = 'ISENTO' then 'isento' else 'pendente' end;
  new.paid_at := null;
  new.paid_by := null;
  return new;
end $$;

-- 4) Registra quem confirmou e quando
create or replace function public.registrations_pay_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.payment_status = 'isento' then
    new.payment_status := 'isento';
  end if;
  if new.payment_status is distinct from old.payment_status then
    if new.payment_status = 'pago' then
      new.paid_at := now();
      new.paid_by := coalesce(auth.jwt() ->> 'email', 'sql');
    else
      new.paid_at := null;
      new.paid_by := null;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists registrations_pay_guard on public.registrations;
create trigger registrations_pay_guard before update on public.registrations
  for each row execute function public.registrations_pay_guard();

-- Nome de quem pagou, quando o Pix saiu de outra conta (sem comprovante)
alter table public.registrations
  add column if not exists payer_name text check (payer_name is null or char_length(payer_name) <= 80);

-- Regulamento: guarda que o inscrito declarou ter 18+ e aceitou o regulamento.
-- Para quem JÁ rodou o tudo.sql antes. Pode rodar de novo sem problema.

alter table public.registrations
  add column if not exists accepted_rules boolean not null default false;
alter table public.registrations
  add column if not exists accepted_at timestamptz;

-- Trava no servidor (versão completa, substitui a anterior)
create or replace function public.registrations_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform pg_advisory_xact_lock(7777);
  if not coalesce((public.inscricoes_status() ->> 'aberta')::boolean, false) then
    raise exception 'Inscrições encerradas' using errcode = 'P0001';
  end if;
  if new.file_url = 'ISENTO'
     and not coalesce((public.inscricoes_status() ->> 'permite_isento')::boolean, true) then
    raise exception 'Inscrição sem cerveja não está disponível' using errcode = 'P0001';
  end if;
  if not coalesce(new.accepted_rules, false) then
    raise exception 'É preciso ter 18 anos ou mais e aceitar o regulamento' using errcode = 'P0001';
  end if;
  new.accepted_at := now();
  new.payment_status := case when new.file_url = 'ISENTO' then 'isento' else 'pendente' end;
  new.paid_at := null;
  new.paid_by := null;
  return new;
end $$;

-- ATUALIZAÇÃO COMPLETA das inscrições: valor para quem não vai beber, pagamento,
-- nome de quem pagou e aceite do regulamento. 0 = grátis para quem não vai beber.
-- Requer o controle de inscrições (tabela registration_settings). Pode rodar de novo sem problema.

-- Colunas de pagamento e regulamento (caso ainda não existam)
alter table public.registrations
  add column if not exists payment_status text not null default 'pendente'
    check (payment_status in ('pendente','pago','isento'));
alter table public.registrations add column if not exists paid_at timestamptz;
alter table public.registrations add column if not exists paid_by text;
alter table public.registrations
  add column if not exists payer_name text check (payer_name is null or char_length(payer_name) <= 80);
alter table public.registrations
  add column if not exists accepted_rules boolean not null default false;
alter table public.registrations add column if not exists accepted_at timestamptz;
update public.registrations set payment_status = 'isento'
 where file_url = 'ISENTO' and payment_status = 'pendente';

revoke update on public.registrations from anon, authenticated;
grant update (payment_status) on public.registrations to authenticated;
drop policy if exists "admin confirma pagamento" on public.registrations;
create policy "admin confirma pagamento" on public.registrations
  for update to authenticated using (true) with check (true);

create or replace function public.registrations_pay_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.payment_status = 'isento' then new.payment_status := 'isento'; end if;
  if new.payment_status is distinct from old.payment_status then
    if new.payment_status = 'pago' then
      new.paid_at := now(); new.paid_by := coalesce(auth.jwt() ->> 'email', 'sql');
    else
      new.paid_at := null; new.paid_by := null;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists registrations_pay_guard on public.registrations;
create trigger registrations_pay_guard before update on public.registrations
  for each row execute function public.registrations_pay_guard();

-- Valor para quem não vai beber

alter table public.registration_settings
  add column if not exists sober_price numeric not null default 0 check (sober_price >= 0);
alter table public.registration_settings
  add column if not exists allow_sober boolean not null default true;

-- Modalidade separada do pagamento, e o valor de cada inscrição
alter table public.registrations
  add column if not exists modality text check (modality in ('cerveja','sobrio'));
alter table public.registrations add column if not exists amount numeric;
update public.registrations
   set modality = case when file_url = 'ISENTO' then 'sobrio' else 'cerveja' end
 where modality is null;

-- Status público (inclui o valor para quem não vai beber)
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
    'valor', s.price, 'valor_sobrio', s.sober_price, 'pagamento', s.payment_info,
    'permite_isento', s.allow_sober);
end $$;
grant execute on function public.inscricoes_status() to anon, authenticated;

-- Trava da inscrição (versão completa): define modalidade, valor e status de pagamento
create or replace function public.registrations_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare s public.registration_settings; sob boolean;
begin
  perform pg_advisory_xact_lock(7777);
  if not coalesce((public.inscricoes_status() ->> 'aberta')::boolean, false) then
    raise exception 'Inscrições encerradas' using errcode = 'P0001';
  end if;
  select * into s from public.registration_settings where id = 1;
  sob := coalesce(new.modality = 'sobrio', new.file_url = 'ISENTO');
  new.modality := case when sob then 'sobrio' else 'cerveja' end;
  if sob and not coalesce(s.allow_sober, true) then
    raise exception 'Inscrição sem cerveja não está disponível' using errcode = 'P0001';
  end if;
  if not coalesce(new.accepted_rules, false) then
    raise exception 'É preciso ter 18 anos ou mais e aceitar o regulamento' using errcode = 'P0001';
  end if;
  new.accepted_at := now();
  if sob and coalesce(s.sober_price, 0) = 0 then
    new.payment_status := 'isento'; new.file_url := 'ISENTO'; new.amount := 0;
  else
    new.payment_status := 'pendente';
    new.amount := case when sob then s.sober_price else s.price end;
    if new.file_url = 'ISENTO' then new.file_url := null; end if;
  end if;
  new.paid_at := null;
  new.paid_by := null;
  return new;
end $$;

-- Preço por lotes para a Corrida do Papai Noel.
-- Execute uma vez no SQL Editor do projeto Supabase usado pelo site.
-- Cada item de price_lots tem {"ate":80,"preco":60}. Faixas começam em 1
-- e seguem sem lacunas. Array vazio mantém o preço único existente.
alter table public.registration_settings
  add column if not exists price_lots jsonb not null default '[]'::jsonb;

create or replace function public.valid_price_lots(lots jsonb)
returns boolean language plpgsql immutable set search_path = ''
as $$
declare item jsonb; previous_end integer := 0; current_end integer; current_price numeric;
begin
  if jsonb_typeof(lots) <> 'array' or jsonb_array_length(lots) > 30 then return false; end if;
  for item in select value from jsonb_array_elements(lots) loop
    if jsonb_typeof(item) <> 'object'
      or not (item ? 'ate') or not (item ? 'preco')
      or jsonb_typeof(item->'ate') <> 'number'
      or jsonb_typeof(item->'preco') <> 'number' then return false; end if;
    current_end := (item->>'ate')::integer;
    current_price := (item->>'preco')::numeric;
    if current_end <= previous_end or current_price <= 0 or current_price > 100000 then return false; end if;
    previous_end := current_end;
  end loop;
  return true;
exception when others then return false;
end $$;

alter table public.registration_settings drop constraint if exists registration_settings_price_lots_check;
alter table public.registration_settings
  add constraint registration_settings_price_lots_check check (public.valid_price_lots(price_lots));

create or replace function public.inscricoes_status()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare s public.registration_settings; n integer; ok boolean; why text;
        next_lot jsonb; lot_number integer; last_end integer; effective_limit integer;
begin
  select * into s from public.registration_settings where id = 1;
  select count(*) into n from public.registrations;
  if s.id is null then
    return jsonb_build_object('aberta', false, 'motivo', 'sem_config', 'total', n);
  end if;
  if jsonb_array_length(s.price_lots) > 0 then
    last_end := (s.price_lots->(jsonb_array_length(s.price_lots)-1)->>'ate')::integer;
    select value, ordinality::integer into next_lot, lot_number
      from jsonb_array_elements(s.price_lots) with ordinality
      where (value->>'ate')::integer > n order by ordinality limit 1;
  end if;
  effective_limit := case when last_end is null then s.max_registrations
    when s.max_registrations is null then last_end
    else least(s.max_registrations,last_end) end;
  if effective_limit is not null and n >= effective_limit then
    ok := false; why := 'limite';
  elsif s.manual_status = 'encerrada' then
    ok := false; why := 'manual';
  elsif s.manual_status = 'aberta' then
    ok := true; why := 'manual';
  elsif s.opens_at is null and s.closes_at is null then
    ok := false; why := 'sem_agenda';
  elsif s.opens_at is not null and now() < s.opens_at then
    ok := false; why := 'antes';
  elsif s.closes_at is not null and now() >= s.closes_at then
    ok := false; why := 'depois';
  else
    ok := true; why := 'agenda';
  end if;
  return jsonb_build_object(
    'aberta', ok, 'motivo', why, 'modo', s.manual_status,
    'total', n, 'limite', effective_limit,
    'abre_em', s.opens_at, 'fecha_em', s.closes_at,
    'valor', coalesce((next_lot->>'preco')::numeric,s.price),
    'lote', lot_number, 'limite_lote', (next_lot->>'ate')::integer,
    'valor_sobrio', s.sober_price, 'pagamento', s.payment_info,
    'permite_isento', s.allow_sober);
end $$;
revoke all on function public.inscricoes_status() from public;
grant execute on function public.inscricoes_status() to anon, authenticated;

create or replace function public.registrations_guard()
returns trigger language plpgsql security definer set search_path = public
as $$
declare s public.registration_settings; sob boolean; current_price numeric; status jsonb;
begin
  perform pg_advisory_xact_lock(7777);
  status := public.inscricoes_status();
  if not coalesce((status->>'aberta')::boolean,false) then
    raise exception 'Inscrições encerradas' using errcode = 'P0001';
  end if;
  select * into s from public.registration_settings where id = 1;
  sob := coalesce(new.modality = 'sobrio', new.file_url = 'ISENTO');
  new.modality := case when sob then 'sobrio' else 'cerveja' end;
  if sob and not coalesce(s.allow_sober,true) then
    raise exception 'Inscrição sem cerveja não está disponível' using errcode = 'P0001';
  end if;
  if not coalesce(new.accepted_rules,false) then
    raise exception 'É preciso ter 18 anos ou mais e aceitar o regulamento' using errcode = 'P0001';
  end if;
  current_price := case when sob then s.sober_price else (status->>'valor')::numeric end;
  if new.amount is not null and new.amount <> current_price then
    raise exception 'O valor do lote mudou; atualize a página e confira o novo preço'
      using errcode = 'P0001';
  end if;
  new.accepted_at := now();
  if sob and coalesce(s.sober_price,0) = 0 then
    new.payment_status := 'isento'; new.file_url := 'ISENTO'; new.amount := 0;
  else
    new.payment_status := 'pendente'; new.amount := current_price;
    if new.file_url = 'ISENTO' then new.file_url := null; end if;
  end if;
  new.paid_at := null; new.paid_by := null;
  return new;
end $$;

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
