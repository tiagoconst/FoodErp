/*
  Como instalar (leva uns 3 minutos):

  1. Abra a PLANILHA DE RESPOSTAS do seu Google Forms (no Forms: aba "Respostas" →
     ícone verde do Sheets, no canto superior direito).
  2. No menu da planilha: Extensões → Apps Script.
  3. Apague o conteúdo padrão (function myFunction(){}) e cole TODO o código abaixo.
  4. Salve (ícone de disquete ou Ctrl+S). Dê um nome pro projeto, ex.: "Envio pro ERP".
  5. No menu lateral esquerdo do Apps Script, clique no ícone de relógio ("Acionadores").
  6. Clique em "+ Adicionar acionador" (canto inferior direito) e configure:
       Função a ser executada: enviarPesquisaProERP
       Evento: Ao enviar formulário
     Salve. Vai pedir pra autorizar o acesso — autorize com sua conta Google (é a mesma
     conta dona da planilha, só está autorizando o próprio script dela a rodar).
  7. Pronto. A partir de agora, toda resposta nova do formulário cai automaticamente no ERP.
  8. Pra trazer as respostas que já existiam ANTES desse gatilho ser criado: selecione
     "importarRespostasAntigas" no menu ao lado do botão "Executar" (lá em cima) e clique em
     Executar — uma vez só. Ela lê tudo que já está na planilha e manda de uma vez pro ERP.

  As perguntas são reconhecidas por um PEDAÇO do texto (não precisa ser igual, letra por
  letra) — então funciona mesmo que você tenha colocado emoji, espaço extra ou uma palavra
  diferente no início da pergunta. Se algum dia mudar muito o texto de uma pergunta, ajuste
  a palavra-chave correspondente lá embaixo, na lista PERGUNTAS.
*/

const SUPABASE_URL = 'https://jaytdbwaoduefrbragsw.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpheXRkYndhb2R1ZWZyYnJhZ3N3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMwMTMwNjgsImV4cCI6MjA5ODU4OTA2OH0.3TBjN82_7bqYRiiuU2b6yNJS1xfJyGtD6bEh7q89kwY';
const EMPRESA_ID = 'dd8275c9-e88f-4633-bfd0-bfa262eaf857';

// pedaço de texto (minúsculo) que identifica cada pergunta, mesmo com emoji/espaço/palavra diferente na frente
const PERGUNTAS = {
  nota_geral: 'nota geral',
  sabor: 'sabor',
  atendimento: 'atendimento',
  recomendaria: 'recomendaria',
  comentario: ['sugestão', 'crítica', 'elogio', 'coment'] // tenta várias, usa a primeira que achar
};

function acharChave(chaves, pedacos) {
  const lista = Array.isArray(pedacos) ? pedacos : [pedacos];
  for (let i = 0; i < lista.length; i++) {
    const alvo = lista[i].toLowerCase();
    const achada = chaves.find(function (k) { return k.toLowerCase().indexOf(alvo) !== -1; });
    if (achada) return achada;
  }
  return null;
}

function enviarPesquisaProERP(e) {
  const v = e.namedValues; // {"texto da pergunta": ["resposta"], ...}
  const chaves = Object.keys(v);
  const pega = function (pedacos) {
    const chave = acharChave(chaves, pedacos);
    return (chave && v[chave] && v[chave][0]) ? v[chave][0].toString().trim() : '';
  };

  const id = 'PSQ-' + Utilities.getUuid().substring(0, 8).toUpperCase();
  const dados = {
    id: id, // o ERP espera o id também dentro do "dados" (mesma convenção de todas as tabelas dele)
    nota_geral: parseInt(pega(PERGUNTAS.nota_geral), 10) || null,
    sabor: pega(PERGUNTAS.sabor),
    atendimento: pega(PERGUNTAS.atendimento),
    recomendaria: pega(PERGUNTAS.recomendaria),
    comentario: pega(PERGUNTAS.comentario),
    respondido_em: Utilities.formatDate(new Date(), 'America/Sao_Paulo', 'yyyy-MM-dd')
  };

  const payload = { id: id, empresa_id: EMPRESA_ID, dados: dados };

  const resp = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/erp_pesquisas', {
    method: 'post',
    contentType: 'application/json',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: 'Bearer ' + SUPABASE_ANON_KEY,
      Prefer: 'return=minimal'
    },
    payload: JSON.stringify(payload),
    muteHttpExceptions: true
  });
  Logger.log('Status: ' + resp.getResponseCode() + ' | Resposta: ' + resp.getContentText() + ' | dados: ' + JSON.stringify(dados));
}

/*
  SÓ PRA TESTAR (não é usada pelo gatilho de verdade — o Forms nunca chama essa função).
  Selecione "testarEnvio" no menu ao lado do botão "Executar" (lá em cima) e clique em
  Executar. Ela finge uma resposta de pesquisa e manda pro Supabase, igual o Forms faria.
  Depois olhe no "Registro de execução" (embaixo) se apareceu "Status: 201" — se sim, deu
  certo, e uma linha de teste vai aparecer no card de Satisfação do ERP.
*/
function testarEnvio() {
  enviarPesquisaProERP({
    namedValues: {
      'De 1 a 5, qual sua nota geral pra essa marmita?': ['5'],
      'Como estava o sabor/tempero?': ['Muito bom'],
      'Como foi o atendimento no seu pedido?': ['Ótimo'],
      'Você recomendaria a Sabores da Ana pra um amigo?': ['Sim'],
      'Tem alguma sugestão, crítica ou elogio que gostaria de deixar? (opcional)': ['Teste de integração — pode ignorar/apagar depois']
    }
  });
}

/*
  IMPORTAR AS RESPOSTAS ANTIGAS (as que já foram respondidas antes do gatilho existir).
  Roda uma vez só. Lê TODAS as linhas já existentes na planilha de respostas e manda pro
  ERP de uma vez — não duplica se você rodar de novo por engano (usa um ID fixo por linha,
  então rodar 2x só substitui os mesmos registros, não cria duplicado).

  Como rodar: selecione "importarRespostasAntigas" no menu ao lado do botão "Executar" e
  clique em Executar. Olhe o "Registro de execução" pra ver quantas respostas foram
  importadas e se deu tudo certo (Status 201).
*/
function importarRespostasAntigas() {
  const aba = SpreadsheetApp.getActiveSpreadsheet().getSheets()[0]; // aba de respostas do Forms
  const valores = aba.getDataRange().getValues();
  if (valores.length < 2) { Logger.log('A planilha não tem nenhuma resposta ainda.'); return; }

  const cabecalho = valores[0];
  const acharIndice = function (pedacos) {
    const lista = Array.isArray(pedacos) ? pedacos : [pedacos];
    for (let i = 0; i < lista.length; i++) {
      const alvo = lista[i].toLowerCase();
      const idx = cabecalho.findIndex(function (h) { return h.toString().toLowerCase().indexOf(alvo) !== -1; });
      if (idx >= 0) return idx;
    }
    return -1;
  };

  const iCarimbo = acharIndice('carimbo');
  const iNota = acharIndice(PERGUNTAS.nota_geral);
  const iSabor = acharIndice(PERGUNTAS.sabor);
  const iAtendimento = acharIndice(PERGUNTAS.atendimento);
  const iRecomenda = acharIndice(PERGUNTAS.recomendaria);
  const iComentario = acharIndice(PERGUNTAS.comentario);

  const faltando = [];
  if (iNota < 0) faltando.push('nota geral');
  if (iSabor < 0) faltando.push('sabor');
  if (iAtendimento < 0) faltando.push('atendimento');
  if (iRecomenda < 0) faltando.push('recomendaria');
  if (faltando.length) {
    Logger.log('ATENÇÃO: não encontrei a coluna de "' + faltando.join('", "') + '" — confira o cabeçalho da planilha (linha 1) e ajuste PERGUNTAS lá em cima. Cabeçalho encontrado: ' + JSON.stringify(cabecalho));
    return;
  }

  const registros = [];
  for (let l = 1; l < valores.length; l++) {
    const linha = valores[l];
    const carimbo = iCarimbo >= 0 ? linha[iCarimbo] : null;
    const dataResp = (carimbo instanceof Date)
      ? Utilities.formatDate(carimbo, 'America/Sao_Paulo', 'yyyy-MM-dd')
      : Utilities.formatDate(new Date(), 'America/Sao_Paulo', 'yyyy-MM-dd');

    const idLinha = 'PSQ-IMP-' + String(l).padStart(4, '0'); // fixo por linha — reexecutar não duplica
    registros.push({
      id: idLinha,
      empresa_id: EMPRESA_ID,
      dados: {
        id: idLinha, // o ERP espera o id também dentro do "dados" (mesma convenção de todas as tabelas dele)
        nota_geral: parseInt(linha[iNota], 10) || null,
        sabor: (linha[iSabor] || '').toString().trim(),
        atendimento: (linha[iAtendimento] || '').toString().trim(),
        recomendaria: (linha[iRecomenda] || '').toString().trim(),
        comentario: iComentario >= 0 ? (linha[iComentario] || '').toString().trim() : '',
        respondido_em: dataResp
      }
    });
  }

  const resp = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/erp_pesquisas', {
    method: 'post',
    contentType: 'application/json',
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: 'Bearer ' + SUPABASE_ANON_KEY,
      Prefer: 'resolution=merge-duplicates,return=minimal'
    },
    payload: JSON.stringify(registros),
    muteHttpExceptions: true
  });
  Logger.log('Importadas ' + registros.length + ' resposta(s) · Status: ' + resp.getResponseCode() + ' | Resposta: ' + resp.getContentText());
}
