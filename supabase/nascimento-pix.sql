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
