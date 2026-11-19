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
