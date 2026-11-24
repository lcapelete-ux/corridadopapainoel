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
