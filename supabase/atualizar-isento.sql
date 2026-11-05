-- Atualização: opção "aceitar inscritos que não vão beber" (liga/desliga no painel)
-- Para quem JÁ rodou tudo.sql antes. Pode rodar de novo sem problema.

alter table public.registration_settings
  add column if not exists allow_sober boolean not null default true;

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
  return new;
end $$;
