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

-- Data de nascimento obrigatória (só maiores de 18 anos) e chave Pix com botão de copiar.
-- Requer supabase/lotes.sql já executado (ou rode o tudo.sql inteiro). Pode rodar de novo sem problema.

alter table public.registrations add column if not exists birth_date date;
alter table public.registration_settings
  add column if not exists pix_key text check (pix_key is null or char_length(pix_key) <= 600);

-- Expõe só a chave Pix (para o botão "Copiar" do formulário), sem abrir a tabela de configurações.
create or replace function public.inscricoes_pix()
returns text
language sql stable security definer set search_path = public
as $$
  select nullif(btrim(pix_key), '') from public.registration_settings where id = 1;
$$;
revoke all on function public.inscricoes_pix() from public;
grant execute on function public.inscricoes_pix() to anon, authenticated;

-- Trava da inscrição: mantém todas as regras anteriores (lotes, valor, regulamento)
-- e passa a exigir a data de nascimento de quem tem 18 anos até 23/12/2026.
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
  -- Data de nascimento obrigatória e só maiores de 18 anos até o dia da corrida (23/12/2026)
  if new.birth_date is null then
    raise exception 'Informe a data de nascimento' using errcode = 'P0001';
  end if;
  if new.birth_date < date '1900-01-01' or new.birth_date > current_date then
    raise exception 'Data de nascimento inválida' using errcode = 'P0001';
  end if;
  if (new.birth_date + interval '18 years')::date > date '2026-12-23' then
    raise exception 'Só maiores de 18 anos podem se inscrever' using errcode = 'P0001';
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

-- Avisar pagamento depois da inscrição (pelo WhatsApp) + WhatsApp obrigatório no banco.
-- Requer supabase/nascimento-pix.sql já executado (ou rode o tudo.sql inteiro). Pode rodar de novo sem problema.

alter table public.registrations add column if not exists payment_notice_at timestamptz;
alter table public.registrations add column if not exists payment_notice text
  check (payment_notice in ('comprovante','declarado'));

-- A pessoa digita o WhatsApp da inscrição e envia o comprovante ou avisa que pagou.
-- Não devolve nenhum dado da inscrição (só ok/motivo) para não expor nomes.
create or replace function public.avisar_pagamento(
  p_phone text, p_file_url text default null, p_payer text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'); r public.registrations;
begin
  if length(d) < 10 then
    return jsonb_build_object('ok', false, 'motivo', 'telefone');
  end if;
  if p_file_url is not null
     and p_file_url !~ '^https://[^/]+/storage/v1/object/public/comprovantes/' then
    return jsonb_build_object('ok', false, 'motivo', 'comprovante');
  end if;
  select * into r from public.registrations
   where right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 10) = right(d, 10)
     and payment_status = 'pendente'
   order by created_at desc limit 1;
  if not found then
    if exists (select 1 from public.registrations
                where right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 10) = right(d, 10)) then
      return jsonb_build_object('ok', false, 'motivo', 'sem_pendencia');
    end if;
    return jsonb_build_object('ok', false, 'motivo', 'nao_encontrado');
  end if;
  update public.registrations
     set file_url = coalesce(p_file_url, file_url),
         payer_name = case when p_file_url is null then coalesce(nullif(btrim(p_payer), ''), payer_name) else payer_name end,
         payment_notice = case when p_file_url is null then 'declarado' else 'comprovante' end,
         payment_notice_at = now()
   where id = r.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.avisar_pagamento(text, text, text) from public;
grant execute on function public.avisar_pagamento(text, text, text) to anon, authenticated;

-- Comprovantes enviados depois da inscrição ficam na pasta "pagamentos" e podem ser enviados
-- mesmo com as inscrições encerradas (a pessoa já está inscrita).
drop policy if exists "publico envia comprovante depois" on storage.objects;
create policy "publico envia comprovante depois" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'comprovantes' and name like 'pagamentos/%');

-- Trava da inscrição (versão completa): mantém tudo e exige WhatsApp válido.
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
  -- WhatsApp obrigatório (com DDD) e comprovante só do nosso armazenamento
  if length(regexp_replace(coalesce(new.phone, ''), '\D', '', 'g')) < 10 then
    raise exception 'Informe um WhatsApp válido, com DDD' using errcode = 'P0001';
  end if;
  if new.file_url is not null and new.file_url <> 'ISENTO'
     and new.file_url !~ '^https://[^/]+/storage/v1/object/public/comprovantes/' then
    raise exception 'Comprovante inválido' using errcode = 'P0001';
  end if;
  -- Data de nascimento obrigatória e só maiores de 18 anos até o dia da corrida (23/12/2026)
  if new.birth_date is null then
    raise exception 'Informe a data de nascimento' using errcode = 'P0001';
  end if;
  if new.birth_date < date '1900-01-01' or new.birth_date > current_date then
    raise exception 'Data de nascimento inválida' using errcode = 'P0001';
  end if;
  if (new.birth_date + interval '18 years')::date > date '2026-12-23' then
    raise exception 'Só maiores de 18 anos podem se inscrever' using errcode = 'P0001';
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

-- Contador de visitas por dia + relatório no painel do admin.
-- Pode rodar de novo sem problema. Não depende dos outros arquivos.

-- Uma linha por visitante por dia (id aleatório e anônimo, sem nome, telefone ou IP).
create table if not exists public.site_visits (
  day         date        not null,
  visitor     text        not null,
  views       integer     not null default 1,      -- quantas vezes abriu o site no dia
  origem      text        not null default 'direto',
  dispositivo text        not null default 'computador',
  first_at    timestamptz not null default now(),
  last_at     timestamptz not null default now(),
  primary key (day, visitor)
);
alter table public.site_visits enable row level security;
-- Sem políticas de leitura: ninguém lê a tabela direto; só pelas funções abaixo.

-- O site chama esta função uma vez por visita (por aba aberta, por dia).
create or replace function public.registrar_visita(
  p_visitor text, p_origem text default 'direto', p_dispositivo text default 'computador')
returns void
language plpgsql security definer set search_path = public
as $$
declare d date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if p_visitor is null or length(p_visitor) not between 8 and 64 then
    return;
  end if;
  insert into public.site_visits (day, visitor, origem, dispositivo)
  values (d, p_visitor,
          case when p_origem in ('instagram','whatsapp','facebook','busca','outros','direto')
               then p_origem else 'direto' end,
          case when p_dispositivo = 'celular' then 'celular' else 'computador' end)
  on conflict (day, visitor)
  do update set views = public.site_visits.views + 1, last_at = now();
end $$;
revoke all on function public.registrar_visita(text, text, text) from public;
grant execute on function public.registrar_visita(text, text, text) to anon, authenticated;

-- Relatório: só para quem está logado no painel.
create or replace function public.relatorio_visitas(p_dias integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare ini date; fim date := (now() at time zone 'America/Sao_Paulo')::date; res jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'authenticated' then
    raise exception 'Acesso restrito' using errcode = '42501';
  end if;
  p_dias := least(greatest(coalesce(p_dias, 30), 1), 365);
  ini := fim - (p_dias - 1);
  select jsonb_build_object(
    'dias', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'dia', g.d::date, 'visitantes', coalesce(v.vis, 0), 'visitas', coalesce(v.vws, 0))
               order by g.d), '[]'::jsonb)
        from generate_series(ini::timestamp, fim::timestamp, interval '1 day') as g(d)
        left join (select day, count(*) as vis, sum(views) as vws
                     from public.site_visits where day between ini and fim group by day) v
               on v.day = g.d::date),
    'total_visitantes', (select count(distinct visitor) from public.site_visits where day between ini and fim),
    'total_visitas',    (select coalesce(sum(views), 0)  from public.site_visits where day between ini and fim),
    'origens', (
      select coalesce(jsonb_agg(jsonb_build_object('origem', origem, 'visitantes', n) order by n desc), '[]'::jsonb)
        from (select origem, count(*) as n from public.site_visits
               where day between ini and fim group by origem) o),
    'dispositivos', (
      select coalesce(jsonb_agg(jsonb_build_object('dispositivo', dispositivo, 'visitantes', n) order by n desc), '[]'::jsonb)
        from (select dispositivo, count(*) as n from public.site_visits
               where day between ini and fim group by dispositivo) x),
    'desde', (select min(day) from public.site_visits)
  ) into res;
  return res;
end $$;
revoke all on function public.relatorio_visitas(integer) from public;
grant execute on function public.relatorio_visitas(integer) to authenticated;

-- Financeiro da corrida: lançamento de despesas e receitas, pagas ou não.
-- Pode rodar de novo sem problema. Não depende dos outros arquivos.
-- Quem vê e lança: usuários logados no painel. Só o marcelo apaga.

create table if not exists public.finance_entries (
  id          bigint generated always as identity primary key,
  tipo        text    not null check (tipo in ('receita','despesa')),
  descricao   text    not null check (char_length(btrim(descricao)) between 1 and 120),
  categoria   text    not null default 'Outras' check (char_length(categoria) <= 60),
  parte       text    check (parte is null or char_length(parte) <= 120),   -- fornecedor ou quem pagou
  valor       numeric(12,2) not null check (valor > 0 and valor < 100000000),
  data        date    not null default ((now() at time zone 'America/Sao_Paulo')::date),
  pago        boolean not null default false,
  pago_em     date,
  criado_por  text,
  criado_em   timestamptz not null default now()
);

alter table public.finance_entries enable row level security;

drop policy if exists "admin le financeiro" on public.finance_entries;
create policy "admin le financeiro" on public.finance_entries
  for select to authenticated using (true);

drop policy if exists "admin lanca financeiro" on public.finance_entries;
create policy "admin lanca financeiro" on public.finance_entries
  for insert to authenticated with check (true);

drop policy if exists "admin altera financeiro" on public.finance_entries;
create policy "admin altera financeiro" on public.finance_entries
  for update to authenticated using (true) with check (true);

drop policy if exists "marcelo apaga financeiro" on public.finance_entries;
create policy "marcelo apaga financeiro" on public.finance_entries
  for delete to authenticated
  using ((auth.jwt() ->> 'email') = 'marcelo@corridanoel.com');

-- Preenche quem lançou e a data do pagamento automaticamente.
create or replace function public.finance_entries_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := coalesce(auth.jwt() ->> 'email', 'sql');
    new.criado_em := now();
  else
    new.criado_por := old.criado_por;
    new.criado_em := old.criado_em;
  end if;
  new.descricao := btrim(new.descricao);
  if new.pago then
    new.pago_em := coalesce(new.pago_em, (now() at time zone 'America/Sao_Paulo')::date);
  else
    new.pago_em := null;
  end if;
  return new;
end $$;

drop trigger if exists finance_entries_guard on public.finance_entries;
create trigger finance_entries_guard before insert or update on public.finance_entries
  for each row execute function public.finance_entries_guard();

-- O público (anon) não acessa nada desta tabela.
revoke all on public.finance_entries from anon;
