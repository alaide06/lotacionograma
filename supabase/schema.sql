-- Schema inicial do Lotacionograma
-- Execute este arquivo no SQL Editor do Supabase.

create extension if not exists pgcrypto;

-- ============================================================
-- Perfis de acesso para o modo autenticado
-- ============================================================
create table if not exists public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'visualizador' check (role in ('admin', 'visualizador')),
  criado_em timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.perfis
    where id = auth.uid()
      and role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- ============================================================
-- Registros de movimentação
-- ============================================================
create table if not exists public.registros (
  id uuid primary key default gen_random_uuid(),
  promotoria text not null,
  titular text,
  tipo text check (
    tipo in (
      'Remoção',
      'Nomeação',
      'Autorização',
      'Afastamento',
      'Acúmulo',
      'Designação',
      'Declaração',
      'Promoção',
      'Outro'
    )
  ),
  destinacao text,
  data_inicial date,
  data_final date,
  situacao text check (
    situacao is null or situacao in (
      'Presente',
      'Futuro',
      'Plantão',
      'Encerrado'
    )
  ),
  referencia text,
  resumo text,
  substituto text,
  data_inicial_substituto date,
  data_final_substituto date,
  situacao_substituto text check (
    situacao_substituto is null or situacao_substituto in (
      'Presente',
      'Futuro',
      'Plantão',
      'Encerrado'
    )
  ),
  referencia_substituto text,
  resumo_substituto text,
  criado_por uuid references auth.users(id) on delete set null default auth.uid(),
  atualizado_por uuid references auth.users(id) on delete set null default auth.uid(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),

  constraint registros_data_principal_valida
    check (data_final is null or data_inicial is null or data_final >= data_inicial),
  constraint registros_data_substituto_valida
    check (
      data_final_substituto is null
      or data_inicial_substituto is null
      or data_final_substituto >= data_inicial_substituto
    )
);

-- ============================================================
-- Lista oficial de promotorias
-- ============================================================
create table if not exists public.promotorias (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  local text check (local is null or lower(trim(local)) in ('interior', 'capital')),
  criado_em timestamptz not null default now()
);

alter table public.promotorias add column if not exists local text;

comment on table public.promotorias is
  'Lista oficial de promotorias disponíveis para seleção no sistema.';

comment on table public.registros is
  'Movimentações de titulares e substitutos por promotoria.';

create index if not exists registros_promotoria_idx
  on public.registros (promotoria);

create index if not exists registros_titular_idx
  on public.registros (titular);

create index if not exists registros_data_inicial_idx
  on public.registros (data_inicial);

create index if not exists registros_situacao_idx
  on public.registros (situacao);

create index if not exists registros_criado_em_idx
  on public.registros (criado_em desc);

-- Aproveita nomes já usados nos registros para iniciar a lista oficial.
insert into public.promotorias (nome)
select distinct trim(promotoria)
from public.registros
where nullif(trim(promotoria), '') is not null
on conflict (nome) do nothing;

-- Migração para instalações que ainda possuem a coluna antiga.
alter table public.registros drop column if exists numero;
alter table public.registros alter column promotoria set not null;
alter table public.registros alter column titular drop not null;
alter table public.registros alter column tipo drop not null;
alter table public.registros add column if not exists situacao_substituto text;

-- Atualiza a lista de tipos aceita também em instalações já existentes.
update public.registros
set tipo = trim(tipo)
where tipo is not null;

update public.registros
set tipo = null
where tipo is not null
  and (
    trim(tipo) = ''
    or tipo not in (
      'Remoção',
      'Nomeação',
      'Autorização',
      'Afastamento',
      'Acúmulo',
      'Designação',
      'Declaração',
      'Promoção',
      'Outro'
    )
  );

alter table public.registros drop constraint if exists registros_tipo_check;
alter table public.registros add constraint registros_tipo_check check (
  tipo is null or tipo in (
    'Remoção',
    'Nomeação',
    'Autorização',
    'Afastamento',
    'Acúmulo',
    'Designação',
    'Declaração',
    'Promoção',
    'Outro'
  )
);

alter table public.registros drop constraint if exists registros_situacao_substituto_check;
alter table public.registros add constraint registros_situacao_substituto_check check (
  situacao_substituto is null or situacao_substituto in (
    'Presente',
    'Futuro',
    'Plantão',
    'Encerrado'
  )
);

-- ============================================================
-- Atualização automática
-- ============================================================
create or replace function public.definir_atualizacao_registro()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.atualizado_em = now();
  new.atualizado_por = auth.uid();
  return new;
end;
$$;

drop trigger if exists registros_definir_atualizacao on public.registros;
create trigger registros_definir_atualizacao
before update on public.registros
for each row
execute function public.definir_atualizacao_registro();

-- ============================================================
-- Segurança: leitura pública; gravações somente pelo painel administrativo do Supabase
-- ============================================================
alter table public.registros enable row level security;
alter table public.perfis enable row level security;
alter table public.promotorias enable row level security;

grant select on public.registros to anon, authenticated;
grant select on public.promotorias to anon, authenticated;
grant select, insert, update, delete on public.registros to authenticated;
revoke insert, update, delete on public.registros from anon;
revoke insert, update, delete on public.promotorias from anon, authenticated;
grant select on public.perfis to authenticated;

drop policy if exists "Leitura pública das promotorias" on public.promotorias;
create policy "Leitura pública das promotorias"
on public.promotorias
for select
to anon, authenticated
using (true);

drop policy if exists "Usuários autenticados podem consultar registros" on public.registros;
drop policy if exists "Leitura pública dos registros" on public.registros;
create policy "Leitura pública dos registros"
on public.registros
for select
to anon, authenticated
using (true);

drop policy if exists "Usuários autenticados podem cadastrar registros" on public.registros;
drop policy if exists "Administradores podem cadastrar registros" on public.registros;
create policy "Administradores podem cadastrar registros"
on public.registros
for insert
to authenticated
with check ((select public.is_admin()));

drop policy if exists "Usuários autenticados podem editar registros" on public.registros;
drop policy if exists "Administradores podem editar registros" on public.registros;
create policy "Administradores podem editar registros"
on public.registros
for update
to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

drop policy if exists "Usuários autenticados podem excluir registros" on public.registros;
drop policy if exists "Administradores podem excluir registros" on public.registros;
create policy "Administradores podem excluir registros"
on public.registros
for delete
to authenticated
using ((select public.is_admin()));

drop policy if exists "Usuário autenticado pode consultar o próprio perfil" on public.perfis;
create policy "Usuário autenticado pode consultar o próprio perfil"
on public.perfis
for select
to authenticated
using ((select auth.uid()) = id or (select public.is_admin()));
