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
