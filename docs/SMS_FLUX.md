# SMS Flux Telecom no JRC Conversas

O canal SMS oferece Twilio, Bandwidth e Flux Telecom. A Flux usa autenticação `account` e `code`, envio JSON por HTTPS e callback para entrega e respostas. A rota da operadora escolhe o remetente; o formulário Flux não solicita telefone de origem.

## Configuração

1. Abra Configurações > Caixas de Entrada > Adicionar caixa > SMS.
2. Selecione Flux Telecom e preencha nome da caixa, Login / Account e Senha / Code.
3. O padrão é `1 - SMS Simples / Longcode`. Outros serviços exigem habilitação da conta Flux. Centro de custo é opcional.
4. Use Testar conexão para consultar um identificador inexistente sem enviar SMS. A criação da caixa permite salvar a configuração antes da liberação do IP.
5. Adicione os agentes. Na aba Configuração, credenciais vazias mantêm os segredos anteriores.

Credenciais e token são criptografados com AES-256-GCM usando uma chave derivada do `SECRET_KEY_BASE` da instalação. Preserve essa chave e os backups do banco. Nenhuma credencial da Flux é incluída no código ou na imagem. Somente administradores podem configurar o canal ou visualizar seu callback.

## API e callback

- Envio: `POST https://apisms.fluxtelecom.com.br/envio`, com `account` e `code` nos headers.
- O suporte confirmou em 28/10/2026 que esse POST não exige `type` no header nem no body. A autenticação usa somente `account` e `code`; `Content-Type: application/json` identifica o formato do corpo. O código atual já segue esse contrato.
- `tipoEnvio` continua obrigatório dentro da mensagem e não é o parâmetro `type`. O `type=C` utilizado pelo teste de conexão pertence à consulta de mensagens em `/integracao3.do`, separada do POST de envio.
- Formato de envio simples da página 24 do manual: `{ "to": "55DDDNUMERO", "tipoEnvio": "2", "msg": "texto", "id": "JRC-SMS-12345" }`. Cada chamada do JRC contém somente uma mensagem, diretamente na raiz do JSON. `client`, `urlCallback` e `tokenCallback` também seguem na raiz.
- O envelope `mensagens`, anteriormente orientado pelo suporte, foi recusado em um teste no laboratório em 28/10/2026: HTTP 200, `Content-Type: text/html;charset=UTF-8`, corpo `PARAMETRO to NO JSON EH OBRIGATORIO E NAO PODE TER VALOR NULL OU VAZIO`. O campo `to` estava presente dentro do envelope. Por isso, o envio foi corrigido para o objeto simples documentado; a aceitação real desse formato ainda precisa ser confirmada no servidor.
- A resposta esperada usa HTTP 200. Erros de aplicação no corpo continuam sendo rejeitados; HTTP 200 e aceitação da solicitação não confirmam entrega no celular. O status enviado mostra que está aguardando a confirmação Flux. A página 25 descreve o retorno do código da mensagem ou do ID informado; o parser aceita esses identificadores, mas não trata qualquer HTTP 200 como sucesso.
- Para a conta tratada com o suporte, foi orientado `tipoEnvio=2`. Selecione essa modalidade na caixa correspondente. As configurações existentes e a modalidade de outras contas não são alteradas automaticamente.
- Correlação: `JRC-SMS-<message_id>`; o identificador retornado pela Flux fica associado à mensagem.
- Callback automático: `https://<host>/f?t=<token-gerado>`. O manual indica limite de 50 caracteres para `urlCallback`; o domínio atual do laboratório resulta em 57. A aceitação integral desse endereço pela Flux ainda precisa ser confirmada. Não corte a URL nem reduza o token para encaixar no limite. A busca MO por API não depende desse callback.
- O token também segue em `tokenCallback`. O endpoint longo `/api/integrations/flux/callback` aceita o mesmo token pelo parâmetro `t`, parâmetro `tokenCallback` ou header `tokenCallback`.
- O corpo aceita uma mensagem ou `{ "mensagens": [...] }`. Após autenticar e enfileirar, responde texto `OK`.
- `ENTREGUE` atualiza a entrega; falhas mantêm o motivo; `RESPOSTA` cria mensagem recebida na conversa correspondente. Callbacks repetidos não duplicam a resposta. Status atrasados não regridem uma entrega confirmada.
- Flux SMS aceita texto: até 160 caracteres nos serviços comuns e até 1280 no SMS Carta. Anexos são recusados com diagnóstico na mensagem.
- Uma falha de confirmação não provoca reenvio automático, evitando cobrança duplicada.

## Imagem e atualização

### Busca automática de respostas como reserva

Na configuração da caixa Flux, a opção `Buscar respostas automaticamente como reserva`
habilita uma consulta MO por minuto ao endpoint HTTPS `/pesquisaResposta`.
O padrão é desativado. Ative somente nas caixas que devem usar essa reserva.
O callback continua ativo e não há alteração da URL ou do token existente.

A consulta usa as credenciais criptografadas da caixa e pesquisa hoje e ontem,
no calendário `America/Sao_Paulo`. Assim pode recuperar respostas recentes
que não chegaram pelo callback, inclusive anteriores à ativação.
Somente referências `JRC-SMS-<id>` de mensagens enviadas pela própria caixa,
com o destinatário original correspondente, são importadas na conversa original.
Registros de outras contas/caixas e envios externos ao JRC são ignorados.
A consulta não envia SMS e não marca o envio original como entregue.
O horário original da Flux fica preservado nos metadados; o registro no JRC
usa o momento da recuperação para manter a atividade e a indicação de não lida.

Cada MO da consulta tem um identificador estável. Reconsultas e callbacks são
conciliados sem duplicar a resposta. IDs de MO diferentes são preservados,
inclusive quando o texto e o segundo de recebimento coincidem.
Respostas anteriores da integração continuam sendo reconhecidas.
Os registros da API usam `;` entre os nove campos e `|` entre registros;
um retorno malformado não é importado parcialmente.

O horário da consulta MO é interpretado em `America/Sao_Paulo`. Os callbacks
com data sem fuso usam UTC, conforme o padrão observado nos eventos recebidos.
Se a Flux confirmar outro fuso para esses callbacks, ajuste
`FLUX_CALLBACK_TIME_ZONE` para a zona informada; datas com offset explícito
respeitam seu próprio offset. Essa configuração interfere na conciliação
entre as duas fontes e deve ser igual nos serviços web e worker.

A execução depende das filas `scheduled_jobs` e `low` no Sidekiq. Há uma trava
por caixa para impedir consultas simultâneas. Ao receber o código de limite
`910`, o sistema pausa as consultas dessa caixa por cinco minutos.
Falhas HTTPS/API não disparam SMS nem repetição imediata da consulta.
O intervalo de um minuto não é garantia de recebimento em exatamente 60 segundos.
Confirme com a Flux os limites de consulta da conta antes de habilitar várias caixas.

Após atualizar web e worker para a mesma imagem, habilite a opção, salve e aguarde
o próximo ciclo. Conferir as respostas recuperadas na conversa original e testar
uma resposta nova. Não é necessário excluir/recriar a caixa ou executar migration.

### Reserva automática para Twilio SMS e WhatsApp

Em Configurações > Caixas de Entrada > caixa Twilio > Configuração, a seção
`Backup SMS via Flux` permite selecionar uma caixa Flux da mesma conta.
O padrão é desativado. Selecionar `Disabled` e salvar desativa a reserva;
trocar ou excluir a caixa de destino também cancela tentativas ainda pendentes.

Após o Twilio aceitar uma mensagem, um job é agendado para 60 segundos depois.
Ele consulta o status no Twilio e verifica novamente o último callback salvo.
`delivered` ou `read` cancela o SMS de reserva. Sem confirmação, realiza uma
única tentativa pela Flux. A execução depende da fila Sidekiq; não é um
temporizador exato no navegador. Se a consulta Twilio estiver indisponível,
o sistema usa a última confirmação local e o texto salvo, mantendo a regra
de uma tentativa. Templates precisam do corpo resolvido obtido do Twilio.

O envio Flux cria uma mensagem na caixa Flux, com o contato e o telefone da
mensagem original. O histórico original exibe separadamente o resultado de
reserva e um link para a conversa SMS, quando o agente tem acesso à caixa.
As respostas ao SMS entram na conversa Flux. O ID e o status original do
Twilio não são substituídos pelo resultado da Flux.

Notas privadas, mensagens excluídas, anexos e destinos fora do formato
brasileiro suportado não são reenviados. O texto deve caber integralmente no
limite do serviço Flux: não há corte ou divisão automática. Bloqueios e
cancelamentos de recebimento informados pelo Twilio (`21610`, `63014`,
`63033`, `63050`) impedem o envio de reserva.

Uma trava no registro original permite somente uma tentativa de reserva,
inclusive com jobs concorrentes ou repetidos. Timeout ou resultado incerto
na Flux não provoca repetição automática. Se o worker parar após iniciar a
tentativa, a interface mantém esse estado para conferência antes de qualquer
reenvio manual. Uma confirmação atrasada do Twilio ainda pode resultar em
duas entregas e duas cobranças: a ausência de confirmação não prova que o
primeiro SMS deixou de chegar.

Configure somente caixas que possam enviar SMS aos destinatários previstos.
Libere o IP público de saída do servidor na Flux antes de ativar a opção.
Esta funcionalidade usa os campos JSON existentes; não adiciona migration.

Imagem da atualização de reserva:

```yaml
image: ghcr.io/claudiohideki/jrcconversa_hs-prevent:4.16.2-jrc-flux-mo-20261028
```

As imagens anteriores `4.16.2-jrc-sms-flux-20261027`, `4.16.2-jrc-flux-fallback-20261028`, `4.16.2-jrc-flux-json-20261028`, `4.16.2-jrc-flux-save-20261028` e `4.16.2-jrc-flux-direct-20261028` permanecem preservadas.

Essa versão também corrige o salvamento da caixa Flux: o campo de criação
`channel.type` não é enviado ao editar, e o backend o ignora em PATCH de canais
existentes. Isso evita `UnknownAttributeError: type for Channel::Sms` em telas
antigas ainda abertas. Erros de salvamento passam a mostrar o motivo real
retornado pelo servidor, em vez de atribuir a falha genericamente a senha/IP.

Build convencional a partir deste código:

```sh
docker build -f docker/Dockerfile -t jrc-conversas:sms-flux-20261027 .
```

Use a mesma imagem para os serviços web e worker. A migration `20261027180000_add_flux_to_sms_channels` adiciona os campos criptografados e permite remetente nulo para a Flux. Planeje backup e execução de `bundle exec rails db:migrate` antes de ativar a nova versão. Esta entrega não executa atualização em produção.

## Homologação pendente

O primeiro teste da integração recebeu código `901`, `IP NAO AUTORIZADO`.
Posteriormente, o usuário confirmou recebimento de SMS enviados pelo laboratório
e duas respostas MO puderam ser consultadas via `/pesquisaResposta` com HTTP 200.
Esses testes reais foram executados pelo usuário, sem credenciais no código.

Os logs fornecidos mostram dois callbacks de status antigos recusados com 401.
O teste de lote vazio na URL atual passou pela autenticação e retornou o 422 esperado.
Não há comprovação de recebimento/processamento dos MOs reais por callback.
Confirmar com a Flux o encaminhamento, a URL completa e o fuso das datas sem offset,
e com o administrador do proxy/Cloudflare eventuais bloqueios anteriores ao Rails.

A busca automática como reserva precisa ser homologada no laboratório após
atualização autorizada da mesma imagem em web e worker e ativação na caixa Flux.
Verificar recuperação das respostas ausentes e chegada de uma nova resposta,
sem duplicações. A confirmação de entrega por callback continua uma validação
separada; consultar MO não substitui o comprovante de entrega da operadora.

Base do contrato: manual Flux WebService e HTTP v2.7.2, envio JSON e callback; especificação técnica JRC fornecida para esta implementação.
