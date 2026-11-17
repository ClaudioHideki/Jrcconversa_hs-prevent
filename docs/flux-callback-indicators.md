# Flux: callback e indicadores de entrega

## Configuracao

O manual Flux v2.7.2 limita `urlCallback` a 50 caracteres. Esse limite inclui
o protocolo, dominio, caminho `/f?t=` e o token existente de cada caixa.
O dominio `https://jrcconversas-lab.jrcws.cloud` gera uma URL de 57 caracteres
com o token de 16 caracteres usado atualmente.

`FLUX_CALLBACK_BASE_URL` permite definir um dominio HTTPS curto exclusivo para
os callbacks Flux. Quando ausente ou vazio, continua sendo usado `FRONTEND_URL`.
O endereco principal, as demais integracoes e os tokens existentes nao mudam.

Antes de configurar essa variavel em uma futura publicacao autorizada:

- Disponibilizar DNS, certificado TLS valido e roteamento para a mesma
  instalacao Rails que enviou o SMS; um nome curto no arquivo de ambiente
  sozinho nao cria esse acesso publico.
- Conferir que a URL completa de cada caixa cabe nos 50 caracteres.
- Manter a autenticacao existente. O token permanece na query `t` e tambem no
  campo `tokenCallback` do envio. A correcao nao depende de a Flux devolver o
  token em um header ou campo nao especificado completamente pelo manual.
- Conferir a configuracao tanto no Rails quanto no Sidekiq da mesma instalacao.
  Nao apontar callbacks do laboratorio para producao.

O adaptador de envio do JRC recusa a tentativa antes de qualquer HTTP se a URL for
longa, malformada ou perder o parametro de autenticacao. O erro nao inclui
o token nem a URL completa. O texto da mensagem e preservado; nao ha reenvio
automatico. HTTPS deve ser usado no endereco publico; HTTP continua aceito
para preservar a configuracao anterior e permitir testes internos isolados.

## Indicadores

O rodape de SMS Flux mostra o ultimo estado recebido por callback:

- Sem confirmacao de envio: aguardando confirmacao de envio.
- Aceitacao sem DLR: aguardando confirmacao de entrega.
- `EM ANALISE` e analise de operadora: em analise na Flux.
- Analise de link: link em analise na Flux.
- `ENVIADA`: enviada pela Flux, sem afirmar entrega.
- `ACEITA`: aceita pela Flux.
- `AGENDADO`: agendada na Flux.
- `ENTREGUE`, apos correlacao valida e gravacao de `delivered`: entregue e dois riscos.
- `BLOQUEADA`, `NAO ENTREGUE` e demais falhas: motivo existente de falha, sem dois riscos.

Estados privados, mensagens recebidas e outros canais nao recebem esse rotulo.
Cada SMS Flux de saida conserva seu indicador mesmo quando a conversa agrupa
mensagens consecutivas; o agrupamento dos outros canais permanece igual.
Metadados com `ENTREGUE` sozinhos nao forcam entrega nem leitura na interface.

## Limites da homologacao

Os testes usam contas e mensagens sinteticas, HTTP bloqueado ou WebMock e
redes/bancos isolados do GitHub Actions. Nenhum SMS real e enviado.
O lint compara os dois arquivos legados Flux com o SHA publicado `7b3377f`.
Infracoes novas ou metricas piores falham a validacao; infracoes preexistentes
nao agravadas sao registradas separadamente, sem alterar os metodos antigos.
Nao foi implementada consulta periodica de DLR; isso evita introduzir consultas
automaticas ao provedor e o erro 910. Os indicadores dependem de callbacks reais.

Esta alteracao nao atualiza mensagens historicas nem muda os enderecos de
callback ja associados pela Flux aos envios anteriores. A retomada de callbacks
pausados ou a confirmacao de resultados existentes exige evidencia do provedor.
O DNS/TLS do dominio curto e a homologacao real continuam pendentes; nenhum
deploy, publicacao de imagem ou alteracao de ambiente faz parte desta validacao.
