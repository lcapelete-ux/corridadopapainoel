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
