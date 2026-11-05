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
