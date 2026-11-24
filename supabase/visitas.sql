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
