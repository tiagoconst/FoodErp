-- Marmita Personalizada: proteína vira OBRIGATÓRIA e ÚNICA por marmita.
--
-- Motivo (decidido em conversa com o Emanuel): estava dando pra montar uma marmita sem escolher
-- nenhuma proteína (caindo no piso genérico de R$17 em vez do preço do prato de verdade) e isso
-- tava gerando prejuízo. Itens vegetarianos (Proteína de Soja, Almôndega de Lentilha) já estão
-- cadastrados na categoria "Proteína", então "obrigatório" cobre vegetariano também — não precisa
-- de exceção. Combinar duas proteínas na mesma marmita não é mais permitido pelo site; quem quiser
-- isso faz por WhatsApp direto com a loja (pedido manual no ERP).
--
-- A validação de verdade tem que ficar no servidor (aqui), não só na tela — o site já mostra o
-- aviso e trava o botão antes, mas isso é só UX; um cliente mal-intencionado podia chamar a
-- função direto no navegador pulando a validação da tela. Essa versão do
-- erp_criar_pedido_publico substitui a anterior (supabase-sob-medida-preco-referencia.sql) —
-- só adiciona a checagem de quantidade de proteína, o resto do corpo é idêntico.
-- Rode direto no SQL Editor do Supabase (não precisa ir pro repositório).

create or replace function public.erp_criar_pedido_publico(
  p_empresa_id uuid,
  p_itens jsonb,
  p_cliente_nome text,
  p_cliente_telefone text,
  p_observacao text,
  p_id_externo text,
  p_cliente_email text default null::text,
  p_cupom_codigo text default null::text,
  p_forma_pagamento text default 'online'::text,
  p_itens_custom jsonb default '[]'::jsonb
)
returns json
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_existente record;
  v_id text;
  v_numero bigint;
  v_bruto numeric := 0;
  v_total_unidades numeric := 0;
  v_desconto_combo numeric := 0;
  v_desconto_unitario numeric := 0;
  v_total numeric := 0;
  v_itens jsonb := '[]'::jsonb;
  v_linha jsonb;
  v_item record;
  v_qtd numeric;
  v_tel_norm text;
  v_cliente_id text;
  v_cliente_existente record;
  v_nome_final text;
  v_auth_uid uuid := auth.uid();
  v_desconto_cupom numeric := 0;
  v_cupom_codigo_aplicado text := null;
  v_cupom_resultado jsonb;
  v_forma_pagamento text;
  COMBO_MIN_UN constant numeric := 5;
  COMBO_DESCONTO_UN constant numeric := 2;
  -- Marmita Personalizada (sob medida)
  v_cfg_sm jsonb;
  v_margem_sm numeric;
  v_min_padrao_sm numeric;
  v_linha_custom jsonb;
  v_comp jsonb;
  v_comp_item record;
  v_gramas numeric;
  v_cu numeric;
  v_custo_marmita numeric;
  v_preco_referencia_marmita numeric;
  v_preco_ref_item numeric;
  v_preco_marmita numeric;
  v_qtd_custom numeric;
  v_detalhe_comp jsonb;
  v_categorias_validas_sm text[] := array['proteína','proteina','carboidrato','carboidratos','legumes/verduras','molho','adicionais'];
  v_categorias_proteina_sm text[] := array['proteína','proteina'];
  v_count_proteina int;
begin
  if not erp_empresa_disponivel_publico(p_empresa_id) then
    raise exception 'Loja indisponível no momento';
  end if;

  if p_id_externo is null or trim(p_id_externo) = '' then
    raise exception 'Requisição inválida';
  end if;

  v_forma_pagamento := case when p_forma_pagamento = 'entrega' then 'entrega' else 'online' end;

  select id, dados->>'valor_total' as valor_total, dados->>'numero' as numero,
         dados->>'desconto_cupom' as desconto_cupom, dados->>'cupom_codigo' as cupom_codigo,
         dados->>'forma_pagamento_desejada' as forma_pagamento_desejada
  into v_existente
  from erp_pedidos
  where empresa_id = p_empresa_id
    and dados->'origem_externa'->>'id_externo' = p_id_externo
  limit 1;
  if found then
    return json_build_object('pedido_id', v_existente.id, 'valor_total', v_existente.valor_total,
      'numero', v_existente.numero, 'desconto_cupom', v_existente.desconto_cupom,
      'cupom_codigo', v_existente.cupom_codigo, 'forma_pagamento_desejada', v_existente.forma_pagamento_desejada,
      'duplicado', true);
  end if;

  if (p_itens is null or jsonb_array_length(p_itens) = 0)
     and (p_itens_custom is null or jsonb_array_length(p_itens_custom) = 0) then
    raise exception 'Pedido vazio';
  end if;

  -- Itens normais do cardápio (igual sempre foi)
  if p_itens is not null then
    for v_linha in select * from jsonb_array_elements(p_itens) loop
      v_qtd := (v_linha->>'quantidade')::numeric;
      if v_qtd is null or v_qtd <= 0 then
        raise exception 'Quantidade inválida';
      end if;

      select id, dados->>'nome' as nome, (dados->>'preco_venda')::numeric as preco_venda,
             coalesce((dados->>'ativo')::boolean, true) as ativo, dados->'funcoes' as funcoes
      into v_item
      from erp_itens
      where empresa_id = p_empresa_id and id = (v_linha->>'item_id');

      if not found or v_item.ativo is not true or not (v_item.funcoes ? 'vendavel') or v_item.preco_venda is null then
        raise exception 'Item indisponível: %', coalesce(v_item.nome, v_linha->>'item_id');
      end if;

      v_bruto := v_bruto + (v_item.preco_venda * v_qtd);
      v_total_unidades := v_total_unidades + v_qtd;
      v_itens := v_itens || jsonb_build_object('item_id', v_item.id, 'quantidade', v_qtd, 'preco_unitario', v_item.preco_venda);
    end loop;
  end if;

  select dados into v_cfg_sm from erp_config where empresa_id = p_empresa_id and id = 'sob_medida_publico';
  v_margem_sm := coalesce((v_cfg_sm->>'margem')::numeric, 0.60);
  v_min_padrao_sm := coalesce((v_cfg_sm->>'preco_minimo_unitario')::numeric, 17);

  if p_itens_custom is not null and jsonb_array_length(p_itens_custom) > 0 then
    for v_linha_custom in select * from jsonb_array_elements(p_itens_custom) loop
      v_qtd_custom := (v_linha_custom->>'quantidade')::numeric;
      if v_qtd_custom is null or v_qtd_custom <= 0 then
        raise exception 'Quantidade inválida numa marmita personalizada';
      end if;
      if v_linha_custom->'componentes' is null or jsonb_array_length(v_linha_custom->'componentes') = 0 then
        raise exception 'Marmita personalizada sem componentes selecionados';
      end if;

      v_custo_marmita := 0;
      v_detalhe_comp := '[]'::jsonb;
      v_preco_referencia_marmita := null; -- preço do prato pronto equivalente à proteína escolhida
      v_count_proteina := 0;

      for v_comp in select * from jsonb_array_elements(v_linha_custom->'componentes') loop
        select i.id as id, i.dados->>'nome' as nome, lower(trim(i.dados->>'categoria')) as categoria,
               coalesce((i.dados->>'ativo')::boolean, true) as ativo
        into v_comp_item
        from erp_itens i
        where i.empresa_id = p_empresa_id and i.id = (v_comp->>'item_id');

        if not found then
          raise exception 'Item não encontrado na marmita personalizada: %', (v_comp->>'item_id');
        end if;
        if not v_comp_item.ativo then
          raise exception '% não está mais disponível pra montagem', v_comp_item.nome;
        end if;
        -- só pré-preparo (PRE-) pode entrar na marmita personalizada, nunca matéria-prima crua
        if v_comp_item.id not like 'PRE-%' then
          raise exception '% não pode ser usado na marmita personalizada', v_comp_item.nome;
        end if;
        if not (v_comp_item.categoria = any(v_categorias_validas_sm)) then
          raise exception '% não pode ser usado na marmita personalizada', v_comp_item.nome;
        end if;

        v_gramas := (v_comp->>'gramas')::numeric;
        if v_gramas is null or v_gramas <= 0 then
          raise exception 'Quantidade inválida para % na marmita personalizada', v_comp_item.nome;
        end if;

        v_cu := erp_custo_item_publico(p_empresa_id, v_comp_item.id);
        if v_cu is null then
          raise exception '% está temporariamente indisponível pra montagem', v_comp_item.nome;
        end if;

        v_custo_marmita := v_custo_marmita + v_cu * v_gramas;
        v_detalhe_comp := v_detalhe_comp || jsonb_build_object('item_id', v_comp_item.id, 'quantidade', v_gramas);

        if v_comp_item.categoria = any(v_categorias_proteina_sm) then
          v_count_proteina := v_count_proteina + 1;
          v_preco_ref_item := erp_preco_referencia_proteina_publico(p_empresa_id, v_comp_item.id);
          if v_preco_ref_item is not null and (v_preco_referencia_marmita is null or v_preco_ref_item > v_preco_referencia_marmita) then
            v_preco_referencia_marmita := v_preco_ref_item;
          end if;
        end if;
      end loop;

      -- Proteína agora é obrigatória e única por marmita personalizada.
      if v_count_proteina = 0 then
        raise exception 'Escolha uma proteína para a marmita personalizada';
      end if;
      if v_count_proteina > 1 then
        raise exception 'A marmita personalizada aceita só uma proteína — pra combinar mais de uma, fale com a gente pelo WhatsApp';
      end if;

      -- Mínimo: preço do prato pronto equivalente (a proteína escolhida). Sem preço de
      -- referência cadastrado pra ela (nenhum produto do cardápio usa essa proteína ainda),
      -- cai no padrão de R$17 — mas a proteína em si já é sempre obrigatória.
      v_preco_marmita := round(greatest(v_custo_marmita * (1 + v_margem_sm), coalesce(v_preco_referencia_marmita, v_min_padrao_sm)), 2);
      v_bruto := v_bruto + v_preco_marmita * v_qtd_custom;
      v_total_unidades := v_total_unidades + v_qtd_custom;
      v_itens := v_itens || jsonb_build_object(
        'item_id', 'PRD-SOB-MEDIDA',
        'quantidade', v_qtd_custom,
        'preco_unitario', v_preco_marmita,
        'nome_custom', 'Marmita Personalizada',
        'componentes', v_detalhe_comp,
        'cmv_unitario', round(v_custo_marmita, 2)
      );
    end loop;
  end if;

  -- Desconto por quantidade (R$2/un a partir de 5 unidades no pedido) — vale igual pra todo
  -- mundo, itens normais e marmita personalizada.
  if v_total_unidades >= COMBO_MIN_UN then
    v_desconto_unitario := COMBO_DESCONTO_UN;
    v_desconto_combo := v_total_unidades * COMBO_DESCONTO_UN;
  end if;
  v_total := greatest(0, v_bruto - v_desconto_combo);

  v_itens := (
    select coalesce(jsonb_agg(jsonb_set(elem, '{preco_unitario}', to_jsonb(greatest(0, (elem->>'preco_unitario')::numeric - v_desconto_unitario)))), '[]'::jsonb)
    from jsonb_array_elements(v_itens) elem
  );

  v_tel_norm := regexp_replace(coalesce(p_cliente_telefone, ''), '\D', '', 'g');
  v_nome_final := coalesce(nullif(trim(p_cliente_nome), ''), 'Cliente do site');
  v_cliente_id := null;

  -- 1) se a pessoa está logada (Google), tenta achar o cadastro dela
  --    pelo login primeiro — é a forma mais confiável de reconhecer
  --    quem já pediu antes, mesmo que troque de telefone.
  if v_auth_uid is not null then
    select id into v_cliente_existente
    from erp_clientes
    where empresa_id = p_empresa_id and dados->>'auth_user_id' = v_auth_uid::text
    limit 1;
    if found then
      v_cliente_id := v_cliente_existente.id;
      update erp_clientes
      set dados = jsonb_set(jsonb_set(dados, '{telefone}', to_jsonb(coalesce(nullif(p_cliente_telefone,''), dados->>'telefone'))), '{email}', to_jsonb(coalesce(p_cliente_email, dados->>'email'))),
          atualizado_em = now()
      where id = v_cliente_id and empresa_id = p_empresa_id;
    end if;
  end if;

  -- 2) senão, cai no esquema de sempre: acha ou cria pelo telefone
  if v_cliente_id is null and v_tel_norm <> '' then
    select id into v_cliente_existente
    from erp_clientes
    where empresa_id = p_empresa_id
      and regexp_replace(coalesce(dados->>'telefone', ''), '\D', '', 'g') = v_tel_norm
      and regexp_replace(coalesce(dados->>'telefone', ''), '\D', '', 'g') <> ''
    limit 1;
    if found then
      v_cliente_id := v_cliente_existente.id;
      -- se achou por telefone e a pessoa está logada agora, vincula o
      -- login a esse cadastro existente (em vez de criar um segundo)
      if v_auth_uid is not null then
        update erp_clientes
        set dados = jsonb_set(jsonb_set(dados, '{auth_user_id}', to_jsonb(v_auth_uid::text)), '{email}', to_jsonb(coalesce(p_cliente_email, dados->>'email'))),
            atualizado_em = now()
        where id = v_cliente_id and empresa_id = p_empresa_id;
      end if;
    else
      v_cliente_id := 'CLI-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
      insert into erp_clientes (id, empresa_id, dados, atualizado_em)
      values (
        v_cliente_id, p_empresa_id,
        jsonb_build_object(
          'id', v_cliente_id,
          'nome', v_nome_final,
          'telefone', p_cliente_telefone,
          'email', p_cliente_email,
          'auth_user_id', v_auth_uid::text,
          'endereco', '',
          'observacao', 'Cadastrado automaticamente pelo site',
          'ativo', true,
          'criado_em', now()
        ),
        now()
      );
    end if;
  end if;

  -- Cupom de desconto (opcional) — valida de novo aqui dentro, no servidor,
  -- não confia no que a prévia do site mostrou antes.
  if p_cupom_codigo is not null and trim(p_cupom_codigo) <> '' then
    v_cupom_resultado := erp_cupom_avaliar(p_empresa_id, p_cupom_codigo, v_total, v_cliente_id, p_cliente_telefone);
    if not coalesce((v_cupom_resultado->>'valido')::boolean, false) then
      raise exception '%', coalesce(v_cupom_resultado->>'motivo', 'Cupom inválido.');
    end if;
    v_desconto_cupom := coalesce((v_cupom_resultado->>'desconto')::numeric, 0);
    v_cupom_codigo_aplicado := v_cupom_resultado->>'codigo';
    v_total := greatest(0, v_total - v_desconto_cupom);
  end if;

  v_id := 'PED-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_numero := erp_proximo_numero_pedido(p_empresa_id);

  insert into erp_pedidos (id, empresa_id, dados, atualizado_em)
  values (
    v_id, p_empresa_id,
    jsonb_build_object(
      'id', v_id,
      'numero', v_numero,
      'cliente_id', v_cliente_id,
      'cliente', v_nome_final,
      'telefone', p_cliente_telefone,
      'canal_id', null,
      'data_pedido', to_char(now(), 'YYYY-MM-DD'),
      'status', 'pedido',
      'itens', v_itens,
      'valor_bruto', v_bruto,
      'desconto_combo', v_desconto_combo,
      'desconto_manual', 0,
      'desconto_cupom', v_desconto_cupom,
      'cupom_codigo', v_cupom_codigo_aplicado,
      'valor_total', v_total,
      'observacao', coalesce(p_observacao, ''),
      'recebido', false,
      'faturamento', null,
      'forma_pagamento_desejada', v_forma_pagamento,
      'origem_externa', jsonb_build_object('canal', 'site', 'id_externo', p_id_externo),
      'criado_em', now()
    ),
    now()
  );

  return json_build_object('pedido_id', v_id, 'numero', v_numero, 'valor_total', v_total,
    'desconto_combo', v_desconto_combo, 'desconto_cupom', v_desconto_cupom,
    'cupom_codigo', v_cupom_codigo_aplicado, 'forma_pagamento_desejada', v_forma_pagamento,
    'cliente_id', v_cliente_id, 'duplicado', false);
end;
$function$;

grant execute on function public.erp_criar_pedido_publico(uuid, jsonb, text, text, text, text, text, text, text, jsonb) to anon, authenticated;
