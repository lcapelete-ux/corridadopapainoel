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
