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
      'Exoneração',
      'Autorização',
      'Afastamento',
      'Acúmulo',
      'Designação',
      'Declaração',
      'Convocação',
      'Termo de Posse',
      'Vacância',
      'Aposentadoria',
      'Instalação',
      'Indicação',
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
alter table public.registros add column if not exists atualizado_por uuid references auth.users(id) on delete set null;
alter table public.registros add column if not exists atualizado_em timestamptz;
update public.registros
set atualizado_em = coalesce(atualizado_em, criado_em, now())
where atualizado_em is null;
alter table public.registros alter column atualizado_em set default now();
alter table public.registros alter column atualizado_em set not null;
create index if not exists registros_atualizado_em_idx
  on public.registros (atualizado_em desc);

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
      'Exoneração',
      'Autorização',
      'Afastamento',
      'Acúmulo',
      'Designação',
      'Declaração',
      'Convocação',
      'Termo de Posse',
      'Vacância',
      'Aposentadoria',
      'Instalação',
      'Indicação',
      'Promoção',
      'Outro'
    )
  );

alter table public.registros drop constraint if exists registros_tipo_check;
alter table public.registros add constraint registros_tipo_check check (
  tipo is null or tipo in (
    'Remoção',
    'Nomeação',
    'Exoneração',
    'Autorização',
    'Afastamento',
    'Acúmulo',
    'Designação',
    'Declaração',
    'Convocação',
    'Termo de Posse',
    'Vacância',
    'Aposentadoria',
    'Instalação',
    'Indicação',
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

-- ============================================================
-- Novas tabelas de membros
-- Execute esta seção também em instalações que já possuem as 3 tabelas.
-- O promotor é um cadastro independente; os vínculos ficam em registros.
-- ============================================================
create table if not exists public.promotores (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  matricula text,
  email text,
  telefone text,
  observacoes text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.substitutos (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  matricula text,
  email text,
  telefone text,
  observacoes text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create unique index if not exists promotores_nome_normalizado_idx
  on public.promotores (lower(trim(nome)));

create unique index if not exists substitutos_nome_normalizado_idx
  on public.substitutos (lower(trim(nome)));

alter table public.registros add column if not exists promotoria_id uuid references public.promotorias(id) on delete set null;
alter table public.registros add column if not exists promotoria_origem text;
alter table public.registros add column if not exists promotoria_origem_id uuid references public.promotorias(id) on delete set null;
alter table public.registros add column if not exists promotor_id uuid references public.promotores(id) on delete set null;
alter table public.registros add column if not exists substituto_id uuid references public.substitutos(id) on delete set null;

create index if not exists registros_promotor_origem_aberto_idx
  on public.registros (promotor_id, promotoria_origem_id, data_final);

update public.registros r
set promotoria_id = p.id
from public.promotorias p
where r.promotoria_id is null
  and lower(trim(r.promotoria)) = lower(trim(p.nome));

insert into public.promotores (nome)
select distinct trim(r.titular)
from public.registros r
where nullif(trim(r.titular), '') is not null
  and not exists (
    select 1 from public.promotores p
    where lower(trim(p.nome)) = lower(trim(r.titular))
  );

-- A mesma lista de promotores também abastece os substitutos dos registros.
insert into public.promotores (nome)
select distinct trim(r.substituto)
from public.registros r
where nullif(trim(r.substituto), '') is not null
  and not exists (
    select 1 from public.promotores p
    where lower(trim(p.nome)) = lower(trim(r.substituto))
  );

insert into public.substitutos (nome)
select distinct trim(r.substituto)
from public.registros r
where nullif(trim(r.substituto), '') is not null
  and not exists (
    select 1 from public.substitutos s
    where lower(trim(s.nome)) = lower(trim(r.substituto))
  );

update public.registros r
set promotor_id = p.id
from public.promotores p
where r.promotor_id is null
  and nullif(trim(r.titular), '') is not null
  and lower(trim(p.nome)) = lower(trim(r.titular));

update public.registros r
set substituto_id = s.id
from public.substitutos s
where r.substituto_id is null
  and nullif(trim(r.substituto), '') is not null
  and lower(trim(s.nome)) = lower(trim(r.substituto));

-- A regra de negócio considera Acúmulo e Designação como registros de substituição.
comment on column public.registros.substituto_id is
  'Substituto do registro; deve ser preenchido quando tipo for Acúmulo ou Designação.';

alter table public.registros drop constraint if exists registros_tipo_check;
alter table public.registros add constraint registros_tipo_check check (
  tipo is null or tipo in (
    'Remoção', 'Nomeação', 'Exoneração', 'Autorização', 'Afastamento',
    'Acúmulo', 'Designação', 'Declaração', 'Convocação', 'Termo de Posse',
    'Vacância', 'Aposentadoria', 'Instalação', 'Indicação', 'Promoção', 'Outro'
  )
);

alter table public.registros drop constraint if exists registros_situacao_check;
alter table public.registros add constraint registros_situacao_check check (
  situacao is null or situacao in ('Presente', 'Futuro', 'Plantão', 'Encerrado')
);

alter table public.registros drop constraint if exists registros_situacao_substituto_check;
alter table public.registros add constraint registros_situacao_substituto_check check (
  situacao_substituto is null or situacao_substituto in ('Presente', 'Futuro', 'Plantão', 'Encerrado')
);

alter table public.registros drop constraint if exists registros_tipo_substituto_check;
alter table public.registros add constraint registros_tipo_substituto_check check (
  tipo is null
  or tipo not in ('Acúmulo', 'Designação')
  or substituto_id is not null
  or nullif(trim(substituto), '') is not null
) not valid;

create or replace function public.definir_atualizacao_membro()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.atualizado_em = now();
  return new;
end;
$$;

drop trigger if exists promotores_definir_atualizacao on public.promotores;
create trigger promotores_definir_atualizacao
before update on public.promotores
for each row execute function public.definir_atualizacao_membro();

drop trigger if exists substitutos_definir_atualizacao on public.substitutos;
create trigger substitutos_definir_atualizacao
before update on public.substitutos
for each row execute function public.definir_atualizacao_membro();

alter table public.promotores enable row level security;
alter table public.substitutos enable row level security;

grant select on public.promotores, public.substitutos to anon, authenticated;
grant select, insert, update, delete on public.promotores, public.substitutos to authenticated;
revoke insert, update, delete on public.promotores, public.substitutos from anon;

drop policy if exists "Leitura pública dos promotores" on public.promotores;
create policy "Leitura pública dos promotores" on public.promotores
for select to anon, authenticated using (true);

drop policy if exists "Administradores podem gerenciar promotores" on public.promotores;
create policy "Administradores podem gerenciar promotores" on public.promotores
for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists "Leitura pública dos substitutos" on public.substitutos;
create policy "Leitura pública dos substitutos" on public.substitutos
for select to anon, authenticated using (true);

drop policy if exists "Administradores podem gerenciar substitutos" on public.substitutos;
create policy "Administradores podem gerenciar substitutos" on public.substitutos
for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- ============================================================
-- Tipos de movimentação cadastráveis
-- ============================================================
create table if not exists public.tipos_movimentacao (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  ativo boolean not null default true,
  exige_substituto boolean not null default false,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

alter table public.tipos_movimentacao
  add column if not exists exige_substituto boolean not null default false;

create unique index if not exists tipos_movimentacao_nome_normalizado_idx
  on public.tipos_movimentacao (lower(trim(nome)));

insert into public.tipos_movimentacao (nome)
select nomes.nome
from (values
  ('Remoção'), ('Nomeação'), ('Autorização'), ('Afastamento'), ('Acúmulo'),
  ('Designação'), ('Declaração'), ('Convocação'), ('Exoneração'),
  ('Termo de Posse'), ('Vacância'), ('Aposentadoria'), ('Instalação'),
  ('Indicação'), ('Promoção'), ('Outro')
) as nomes(nome)
where not exists (
  select 1 from public.tipos_movimentacao t
  where lower(trim(t.nome)) = lower(trim(nomes.nome))
);

update public.tipos_movimentacao
set exige_substituto = true
where lower(trim(nome)) in (lower('Acúmulo'), lower('Designação'));

-- Preserva tipos personalizados que já possam existir nos registros.
insert into public.tipos_movimentacao (nome)
select distinct trim(r.tipo)
from public.registros r
where nullif(trim(r.tipo), '') is not null
  and not exists (
    select 1 from public.tipos_movimentacao t
    where lower(trim(t.nome)) = lower(trim(r.tipo))
  );

alter table public.registros add column if not exists tipo_id uuid references public.tipos_movimentacao(id) on delete set null;
alter table public.registros drop constraint if exists registros_tipo_check;

update public.registros r
set tipo_id = t.id
from public.tipos_movimentacao t
where r.tipo_id is null
  and nullif(trim(r.tipo), '') is not null
  and lower(trim(r.tipo)) = lower(trim(t.nome));

create index if not exists registros_tipo_id_idx on public.registros (tipo_id);

create or replace function public.validar_substituto_do_registro()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  tipo_exige_substituto boolean := false;
begin
  select coalesce(t.exige_substituto, false)
    into tipo_exige_substituto
  from public.tipos_movimentacao t
  where t.id = new.tipo_id;

  if tipo_exige_substituto
     or lower(trim(coalesce(new.tipo, ''))) in ('acúmulo', 'designação') then
    if new.substituto_id is null and nullif(trim(coalesce(new.substituto, '')), '') is null then
      raise exception 'O tipo de movimentação exige um substituto.' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists registros_validar_substituto on public.registros;
create trigger registros_validar_substituto
before insert or update on public.registros
for each row execute function public.validar_substituto_do_registro();

create or replace function public.definir_atualizacao_tipo_movimentacao()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.atualizado_em = now();
  return new;
end;
$$;

drop trigger if exists tipos_movimentacao_definir_atualizacao on public.tipos_movimentacao;
create trigger tipos_movimentacao_definir_atualizacao
before update on public.tipos_movimentacao
for each row execute function public.definir_atualizacao_tipo_movimentacao();

alter table public.tipos_movimentacao enable row level security;
grant select on public.tipos_movimentacao to anon, authenticated;
grant select, insert, update, delete on public.tipos_movimentacao to authenticated;
revoke insert, update, delete on public.tipos_movimentacao from anon;

drop policy if exists "Leitura pública dos tipos de movimentação" on public.tipos_movimentacao;
create policy "Leitura pública dos tipos de movimentação" on public.tipos_movimentacao
for select to anon, authenticated using (true);

drop policy if exists "Administradores podem gerenciar tipos de movimentação" on public.tipos_movimentacao;
create policy "Administradores podem gerenciar tipos de movimentação" on public.tipos_movimentacao
for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

-- ============================================================
-- Consolidação: titular e substituto usam a tabela promotores
-- ============================================================
-- Preserva nomes que só existiam na tabela antiga de substitutos.
insert into public.promotores (nome, observacoes)
select distinct s.nome, s.observacoes
from public.substitutos s
where nullif(trim(s.nome), '') is not null
  and not exists (
    select 1 from public.promotores p
    where lower(trim(p.nome)) = lower(trim(s.nome))
  );

-- Remove a FK antiga antes de trocar os IDs de substitutos pelos IDs de promotores.
do $$
declare
  nome_constraint text;
begin
  select c.conname
    into nome_constraint
  from pg_constraint c
  where c.conrelid = 'public.registros'::regclass
    and c.confrelid = 'public.substitutos'::regclass
    and c.contype = 'f'
  limit 1;

  if nome_constraint is not null then
    execute format('alter table public.registros drop constraint %I', nome_constraint);
  end if;
end;
$$;

update public.registros r
set substituto_id = p.id
from public.substitutos s
join public.promotores p on lower(trim(p.nome)) = lower(trim(s.nome))
where r.substituto_id = s.id;

update public.registros r
set substituto_id = p.id
from public.promotores p
where r.substituto_id is null
  and nullif(trim(r.substituto), '') is not null
  and lower(trim(p.nome)) = lower(trim(r.substituto));

alter table public.registros drop constraint if exists registros_substituto_id_fkey;
alter table public.registros
  add constraint registros_substituto_id_fkey
  foreign key (substituto_id) references public.promotores(id) on delete set null;

drop table if exists public.substitutos;

-- ============================================================
-- Afastamentos por dia
-- ============================================================
-- Cada linha representa um dia específico. Isso permite registrar
-- datas não consecutivas e contabilizar os dias sem cálculos frágeis.
create table if not exists public.afastamento_subtipos (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  ativo boolean not null default true,
  criado_por uuid references auth.users(id) on delete set null default auth.uid(),
  criado_em timestamptz not null default now()
);

create unique index if not exists afastamento_subtipos_nome_normalizado_idx
  on public.afastamento_subtipos (lower(trim(nome)));

insert into public.afastamento_subtipos (nome)
select nomes.nome
from (values
  ('Férias'),
  ('Folgas Plantão'),
  ('Tratamento de saúde')
) as nomes(nome)
where not exists (
  select 1 from public.afastamento_subtipos s
  where lower(trim(s.nome)) = lower(trim(nomes.nome))
);

create table if not exists public.afastamentos_dias (
  id uuid primary key default gen_random_uuid(),
  promotor_id uuid not null references public.promotores(id) on delete restrict,
  subtipo_id uuid not null references public.afastamento_subtipos(id) on delete restrict,
  data date not null,
  referencia text,
  observacao text,
  criado_por uuid references auth.users(id) on delete set null default auth.uid(),
  criado_em timestamptz not null default now(),
  constraint afastamentos_dias_membro_data_unique unique (promotor_id, data)
);

create index if not exists afastamentos_dias_promotor_data_idx
  on public.afastamentos_dias (promotor_id, data desc);

create index if not exists afastamentos_dias_subtipo_data_idx
  on public.afastamentos_dias (subtipo_id, data desc);

alter table public.afastamento_subtipos enable row level security;
alter table public.afastamentos_dias enable row level security;

grant select on public.afastamento_subtipos, public.afastamentos_dias to anon, authenticated;
grant insert, update, delete on public.afastamento_subtipos, public.afastamentos_dias to authenticated;
revoke insert, update, delete on public.afastamento_subtipos, public.afastamentos_dias from anon;

drop policy if exists "Leitura pública dos subtipos de afastamento" on public.afastamento_subtipos;
create policy "Leitura pública dos subtipos de afastamento"
on public.afastamento_subtipos for select to anon, authenticated using (true);

drop policy if exists "Administradores gerenciam subtipos de afastamento" on public.afastamento_subtipos;
create policy "Administradores gerenciam subtipos de afastamento"
on public.afastamento_subtipos for all to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

drop policy if exists "Leitura pública dos afastamentos" on public.afastamentos_dias;
create policy "Leitura pública dos afastamentos"
on public.afastamentos_dias for select to anon, authenticated using (true);

drop policy if exists "Administradores gerenciam afastamentos" on public.afastamentos_dias;
create policy "Administradores gerenciam afastamentos"
on public.afastamentos_dias for all to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));
