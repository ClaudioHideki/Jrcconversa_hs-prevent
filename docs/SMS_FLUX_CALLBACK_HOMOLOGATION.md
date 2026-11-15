# Callbacks Flux: conferência antes da publicação

Esta conferência usa o código local e o manual Flux WebService/HTTP v2.7.2,
seção 7.3 e tabelas do envio JSON. Não consulta produção nem usa credenciais reais.
O manual descreve o contrato; habilitação de DLR e comportamento da conta/rota
precisam ser confirmados com a Flux. Ausência de `delivered` não prova defeito no webhook.

## Contrato implementado e validação local

| Ponto | Comportamento |
| --- | --- |
| Aceitação do envio | Resposta de sucesso do envio mantém `sent` (✓); não comprova entrega. |
| DLR | Somente `ENTREGUE` correlacionado confirma `delivered` (✓✓). Não existe leitura SMS neste contrato. |
| MO | `RESPOSTA` e consulta `/pesquisaResposta` representam respostas recebidas; não substituem DLR. |
| URL | `FRONTEND_URL` sem barra final + `/f?t=<token>`; também existe `/api/integrations/flux/callback`. Ambas recebem POST. |
| Autenticação | Token gerado e criptografado da caixa, distinto de account/code. Aceito em `t`, header `tokenCallback` ou campo JSON `tokenCallback`, nessa precedência. |
| Limites do manual | `urlCallback`: String de até 50 caracteres; `tokenCallback`: até 50. O token deve ser string e não pode exceder 50 bytes no receptor. |
| Corpo | Evento único ou objeto com `mensagens`, entre 1 e 1.000 objetos. Campos não previstos, inclusive autenticação, não seguem no job. |
| HTTP 200 | Corpo literal `OK` após enfileirar. Confirma recebimento do callback; processamento e entrega são etapas distintas. |
| HTTP 401 | Token ausente, desconhecido, excessivo ou com tipo inválido. Não enfileira. |
| HTTP 422 | Envelope/lote inválido. Não enfileira. |
| Falha da fila | Resposta de erro, sem `OK`; o teste de indisponibilidade reproduz HTTP 500. |
| Correlação | Token seleciona a caixa Flux; parceiro `JRC-SMS-<id>`, ID Flux, destinatário, conta e caixa devem corresponder. IDs provisórios existentes são reconhecidos. |
| Datas | Parser existente respeita offsets; sem offset usa `FLUX_CALLBACK_TIME_ZONE` (padrão UTC). Não ordenar datas como strings. |
| Worker | `Webhooks::FluxEventsJob` usa fila `default`. Broadcast e despacho usam `critical`; ambas constam em `config/sidekiq.yml`. |
| Idempotência | Duplicatas e eventos fora de ordem não regridem a entrega nem duplicam mensagens. Eventos desconhecidos não fabricam entrega. |

O manual informa que o encaminhamento pode ser pausado se não houver resposta `OK`.
Não presume repetição automática ou retomada do provedor. Um 200 também não prova
que o worker processou: conferir fila, erros e resultado persistido pelo ID do job.

O padrão de criação da caixa continua `tipoEnvio=1`; a modalidade operacional
informada pelo usuário é `2`. A modalidade efetiva vem da configuração salva da
caixa. Não houve consulta nem alteração dessa configuração em produção. Os limites
existentes de 160 caracteres e Carta tipo 4 de 1.280 continuam preservados,
assim como Unicode por Ruby `String#length`, expansão Liquid e rascunhos.

## O que precisa de homologação real autorizada

1. Confirmar com a Flux se a conta/rota/modalidade fornece DLR e se encaminha os
   estados finais para a URL informada. Usar primeiro IDs já existentes; não enviar
   SMS novos sem autorização específica.
2. Conferir a URL efetiva completa e seu comprimento com acesso administrativo
   autorizado, sem imprimir/copiar o token em logs ou chamados. O código não corta
   a URL nem reduz tokens. Se exceder o limite documentado, alinhar uma solução
   aceita pelo provedor antes de alterar domínio, caminho ou autenticação.
3. Conferir externamente HTTPS/TLS, DNS, proxy/WAF, método POST, caminho sem
   redirecionamentos inesperados e repasse do token/corpo. Não presumir que o
   provedor envia `tokenCallback` em um header sem confirmação de seu transporte.
4. Obter evidência anonimizada: ID do provedor/parceiro, status, horário/fuso,
   tentativa de callback, HTTP/corpo recebido pela Flux e identificação do job.
   Não compartilhar telefone completo, mensagem, token, account/code ou credenciais.
5. Verificar worker ativo nas filas `default` e `critical`, mesmo Redis, mesma
   revisão de código e mesmas configurações de callback/fuso do web. Preservar
   `SECRET_KEY_BASE`; não recriar caixas, rotacionar tokens ou regravar históricos
   como tentativa de diagnóstico.
6. Validar que um DLR real corresponde à mensagem original, chega à interface sem
   refresh e não regride após eventos atrasados. Confirmar política de retomada se
   houve 401/422/5xx ou pausa na Flux. A recuperação de DLR antigo depende da Flux;
   não marcar mensagens históricas como entregues por inferência.

Nesta etapa não foi feita nenhuma chamada à Flux, consulta de produção, rotação de
credenciais, mudança de modalidade ou envio real. A chegada e habilitação do DLR
real permanecem uma pendência externa, separada dos testes locais.

## Logs e execução

`ActionCableBroadcastJob`, `EventDispatcherJob` e `Webhooks::FluxEventsJob` omitem
argumentos nos logs ActiveJob. Classe, job ID, fila, duração e resultado continuam
disponíveis. O descarte por GlobalID inválido não imprime o payload serializado.
O logger padrão de falhas Sidekiq respeita essa política por job, preservando IDs,
fila, tentativas, classe da exceção e backtrace; não despeja `jobstr` bruto.

Essa proteção não modifica os argumentos usados na execução, a fila de retry, os
destinatários de broadcast, permissões ou auditoria do aplicativo. Dados necessários
à execução permanecem no Redis; isso exige os controles de acesso existentes.
Não houve alteração global de `log_arguments`, nível de log ou integrações APM/Sentry.
As configurações opcionais de telemetria da instalação não foram consultadas.
