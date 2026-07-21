-- ============================================================
-- Permite que o site de pedidos busque o cadastro salvo de quem
-- está logado com Google, para preencher nome E telefone
-- automaticamente da segunda vez que a pessoa pedir (a primeira vez
-- ainda precisa digitar o telefone, porque o Google não compartilha
-- esse dado).
-- ============================================================
create or replace function public.erp_meu_cadastro_publico(p_empresa_id uuid)
returns json
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when auth.uid() is null then null else (
    select json_build_object('nome', dados->>'nome', 'telefone', dados->>'telefone')
    from erp_clientes
    where empresa_id = p_empresa_id and dados->>'auth_user_id' = auth.uid()::text
    limit 1
  ) end;
$$;

-- só faz sentido pra quem está logado (auth.uid() não nulo), então só
-- precisa de permissão pra "authenticated", não pra "anon"
grant execute on function public.erp_meu_cadastro_publico(uuid) to authenticated;
