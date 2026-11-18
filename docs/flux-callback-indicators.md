# Flux: callback e indicadores de entrega

## Configuracao

O manual Flux v2.7.2 limita `urlCallback` a 50 caracteres. Em esclarecimento
posterior, o suporte confirmou que `tokenCallback`, enviado pelo JRC, retorna no
campo JSON `token` de cada evento. O receptor aceita esse formato em eventos
individuais e no envelope `mensagens`, sem incluir o segredo nos argumentos do job.

Novos envios usam somente `/f` na URL e conservam `tokenCallback` no corpo da
requisicao de envio. Nenhum token ou credencial existente e rotacionado. A URL
padrao `https://jrcconversas-lab.jrcws.cloud/f` tem 38 caracteres. O alias
`https://flap.jrcws.cloud/f` tem 26. Nao e necessario criar outro dominio quando
a URL padrao ja respeita o limite e possui HTTPS e roteamento validos.

`FLUX_CALLBACK_BASE_URL` continua como override opcional exclusivo do Flux;
quando vazio, usa `FRONTEND_URL`. Nao altera o endereco principal nem as outras
integracoes. Rails e Sidekiq devem usar a configuracao da mesma instalacao.

O token JSON tem prioridade sobre o antigo `?t=`. Um token JSON invalido nao
recorre ao token da URL. Eventos com tokens diferentes no mesmo lote sao
recusados antes do enfileiramento. Requisicoes antigas sem `token` JSON continuam
aceitando `t`, o header `tokenCallback` ou o antigo campo `tokenCallback`.
A correlacao continua restrita a caixa, conta, identificador e destinatario.

O adaptador recusa antes de qualquer HTTP URLs acima de 50 caracteres,
malformadas, com credenciais embutidas, query ou fragmento. Erros nao incluem
tokens. O conteudo e preservado e nao ha reenvio automatico. HTTPS deve ser usado
publicamente; HTTP continua aceito para compatibilidade e testes isolados.

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
O suporte confirmou tentativas reais com HTTP 401 e desativacao automatica do
callback global antigo. Isso comprova a falha de autenticacao, mas nao comprova
qual token foi comparado em cada tentativa. O formato JSON confirmado nao era
aceito pelo receptor anterior. DNS/HTTPS e comprimento correto, sozinhos, nao
homologam a autenticacao nem a entrega de eventos.

Depois de uma futura publicacao e instalacao autorizadas, confirmar com a Flux
por canal seguro a URL e o token da caixa correta e solicitar somente o replay
do callback da mensagem indicada. Nao reenviar o SMS. Como laboratorio e producao
compartilham a conta Flux, nao trocar URLs globais, credenciais ou reativar lotes
sem confirmar que o procedimento nao afeta producao. Conferir HTTP 200 e corpo
`OK`, processamento do worker, correlacao, persistencia e atualizacao da interface.
A homologacao real permanece pendente. Nenhum deploy, publicacao de imagem ou
alteracao de ambiente faz parte desta validacao.
