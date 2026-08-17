-- =============================================================================
-- POAE · Sala ao Vivo — migração 0003
-- CORREÇÃO CRÍTICA.
--
-- Na 0001 as políticas de leitura consultavam as próprias tabelas que
-- protegiam. O Postgres reaplica a RLS dentro da subconsulta e entra em
-- recursão infinita, derrubando qualquer SELECT em 'participantes' e,
-- por tabela, em 'sessoes', 'respostas' e 'termos'.
--
-- Solução: mover a verificação para funções SECURITY DEFINER. Elas rodam
-- como dono da tabela, não reaplicam RLS, e por isso quebram o ciclo.
--
-- Aproveita para devolver sessao_id direto de sala_entrar, eliminando uma
-- consulta extra do cliente.
-- =============================================================================

-- 1. Funções de verificação ----------------------------------------------------

create or replace function public.sala_sou_host(p_sessao uuid)
returns boolean language sql stable
security definer set search_path = public
as $$ select exists (select 1 from public.sessoes
                     where id = p_sessao and host = auth.uid()); $$;

create or replace function public.sala_sou_membro(p_sessao uuid)
returns boolean language sql stable
security definer set search_path = public
as $$ select exists (select 1 from public.participantes
                     where sessao_id = p_sessao and auth_id = auth.uid()); $$;

create or replace function public.sala_meu_participante(p_id uuid)
returns boolean language sql stable
security definer set search_path = public
as $$ select exists (select 1 from public.participantes
                     where id = p_id and auth_id = auth.uid()); $$;

create or replace function public.sala_sessao_do_item(p_item uuid)
returns uuid language sql stable
security definer set search_path = public
as $$ select sessao_id from public.itens where id = p_item; $$;

-- 2. Políticas reescritas ------------------------------------------------------

drop policy if exists sessoes_leitura       on public.sessoes;
drop policy if exists itens_leitura         on public.itens;
drop policy if exists participantes_leitura on public.participantes;
drop policy if exists respostas_proprias    on public.respostas;
drop policy if exists termos_leitura        on public.termos;

create policy sessoes_leitura on public.sessoes for select to authenticated
using ( host = auth.uid() or public.sala_sou_membro(id) );

create policy itens_leitura on public.itens for select to authenticated
using ( public.sala_sou_host(sessao_id) or public.sala_sou_membro(sessao_id) );

-- O host precisava enxergar os participantes para contar quem está conectado.
-- Na 0001 ele não conseguia. Corrigido aqui.
create policy participantes_leitura on public.participantes for select to authenticated
using ( public.sala_sou_host(sessao_id) or public.sala_sou_membro(sessao_id) );

create policy respostas_proprias on public.respostas for select to authenticated
using ( public.sala_meu_participante(participante_id) );

create policy termos_leitura on public.termos for select to authenticated
using (
  public.sala_sou_host(public.sala_sessao_do_item(item_id))
  or (aprovado and public.sala_sou_membro(public.sala_sessao_do_item(item_id)))
);

-- 3. sala_entrar devolve a sessão -----------------------------------------------

drop function if exists public.sala_entrar(text, text, text);

create or replace function public.sala_entrar(
  p_codigo  text,
  p_apelido text,
  p_papel   text default 'aluno'
)
returns jsonb
language plpgsql
security definer set search_path = public
as $$
declare
  v_sessao  uuid;
  v_cod     text;
  v_apelido text;
  v_id      uuid;
begin
  if auth.uid() is null then raise exception 'AUTENTICACAO_AUSENTE'; end if;
  if p_papel not in ('aluno','telao') then raise exception 'PAPEL_INVALIDO'; end if;

  select id, codigo into v_sessao, v_cod
  from public.sessoes
  where codigo = upper(trim(p_codigo)) and fase <> 'encerrada';
  if v_sessao is null then raise exception 'SALA_NAO_ENCONTRADA'; end if;

  select id into v_id
  from public.participantes
  where sessao_id = v_sessao and auth_id = auth.uid();

  if v_id is null then
    if p_papel = 'telao' then
      v_apelido := 'telao-' || left(replace(auth.uid()::text,'-',''), 6);
    else
      v_apelido := trim(coalesce(p_apelido,''));
      if char_length(v_apelido) < 2 or char_length(v_apelido) > 20 then
        raise exception 'APELIDO_INVALIDO';
      end if;
      if exists (
        select 1 from public.termos_bloqueados b
        where public.normalizar_termo(v_apelido) like '%' || b.termo || '%'
      ) then
        raise exception 'APELIDO_RECUSADO';
      end if;
    end if;

    insert into public.participantes (sessao_id, auth_id, apelido, papel)
    values (v_sessao, auth.uid(), v_apelido, p_papel)
    returning id into v_id;
  end if;

  return jsonb_build_object(
    'participante_id', v_id,
    'sessao_id',       v_sessao,
    'codigo',          v_cod
  );
exception
  when unique_violation then
    if p_papel = 'telao' then raise exception 'TELAO_JA_CONECTADO'; end if;
    raise exception 'APELIDO_EM_USO';
end $$;

-- 4. Verificação ----------------------------------------------------------------
-- Esperado: recursao_participantes = false (nenhuma política self-referente),
-- politicas = 5, e sala_entrar devolvendo jsonb.
select
  (select count(*) from pg_policies
    where schemaname='public' and tablename='participantes'
      and qual like '%from participantes%')::int          as politicas_recursivas,
  (select count(*) from pg_policies where schemaname='public')::int as politicas,
  (select pg_get_function_result(p.oid)
     from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='sala_entrar')  as retorno_sala_entrar;
