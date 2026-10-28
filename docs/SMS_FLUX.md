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
- Formato confirmado pelo suporte Flux em 28/10/2026: `{ "mensagens": [ { "to": "55DDDNUMERO", "tipoEnvio": "2", "msg": "texto", "id": "JRC-SMS-12345" } ] }`. Cada chamada do JRC contém somente uma mensagem. `client`, `urlCallback` e `tokenCallback` seguem dentro desse item.
- O suporte confirmou a mesma URL `/envio` para esse envelope, com HTTP 200 como resposta esperada. Erros de aplicação no corpo continuam sendo rejeitados; HTTP 200 e aceitação da solicitação não confirmam entrega no celular. O status enviado mostra que está aguardando a confirmação Flux.
- Para a conta tratada com o suporte, foi orientado `tipoEnvio=2`. Selecione essa modalidade na caixa correspondente. As configurações existentes e a modalidade de outras contas não são alteradas automaticamente.
- Correlação: `JRC-SMS-<message_id>`; o identificador retornado pela Flux fica associado à mensagem.
- Callback automático: `https://<host>/f?t=<token-gerado>`. O formato curto cabe nos 50 caracteres documentados para o host JRC informado. Verifique esse limite se alterar o domínio da instalação.
- O token também segue em `tokenCallback`. O endpoint longo `/api/integrations/flux/callback` aceita o mesmo token pelo parâmetro `t`, parâmetro `tokenCallback` ou header `tokenCallback`.
- O corpo aceita uma mensagem ou `{ "mensagens": [...] }`. Após autenticar e enfileirar, responde texto `OK`.
- `ENTREGUE` atualiza a entrega; falhas mantêm o motivo; `RESPOSTA` cria mensagem recebida na conversa correspondente. Callbacks repetidos não duplicam a resposta. Status atrasados não regridem uma entrega confirmada.
- Flux SMS aceita texto: até 160 caracteres nos serviços comuns e até 1280 no SMS Carta. Anexos são recusados com diagnóstico na mensagem.
- Uma falha de confirmação não provoca reenvio automático, evitando cobrança duplicada.

## Imagem e atualização

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
image: ghcr.io/claudiohideki/jrcconversa_hs-prevent:4.16.2-jrc-flux-save-20261028
```

As imagens anteriores `4.16.2-jrc-sms-flux-20261027`, `4.16.2-jrc-flux-fallback-20261028` e `4.16.2-jrc-flux-json-20261028` permanecem preservadas.

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

A API respondeu com HTTPS e certificado verificado. A consulta autenticada realizada nesta sessão recebeu HTTP 200 com código de aplicação `901`, `IP NAO AUTORIZADO`. É necessário cadastrar na Flux o IP público de saída do servidor que realizará os envios. O IP do computador de desenvolvimento não substitui esse IP.

Depois da liberação, testar com um celular autorizado: envio, confirmação de entrega e resposta do cliente na mesma conversa. Essa homologação real não foi concluída; nenhum SMS real foi enviado nesta sessão. Confirmar também a habilitação de callback/MO e dos serviços escolhidos junto à Flux.

Base do contrato: manual Flux WebService e HTTP v2.7.2, envio JSON e callback; especificação técnica JRC fornecida para esta implementação.
