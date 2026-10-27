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
- Correlação: `JRC-SMS-<message_id>`; o identificador retornado pela Flux fica associado à mensagem.
- Callback automático: `https://<host>/f?t=<token-gerado>`. O formato curto cabe nos 50 caracteres documentados para o host JRC informado. Verifique esse limite se alterar o domínio da instalação.
- O token também segue em `tokenCallback`. O endpoint longo `/api/integrations/flux/callback` aceita o mesmo token pelo parâmetro `t`, parâmetro `tokenCallback` ou header `tokenCallback`.
- O corpo aceita uma mensagem ou `{ "mensagens": [...] }`. Após autenticar e enfileirar, responde texto `OK`.
- `ENTREGUE` atualiza a entrega; falhas mantêm o motivo; `RESPOSTA` cria mensagem recebida na conversa correspondente. Callbacks repetidos não duplicam a resposta. Status atrasados não regridem uma entrega confirmada.
- Flux SMS aceita texto: até 160 caracteres nos serviços comuns e até 1280 no SMS Carta. Anexos são recusados com diagnóstico na mensagem.
- Uma falha de confirmação não provoca reenvio automático, evitando cobrança duplicada.

## Imagem e atualização

Build convencional a partir deste código:

```sh
docker build -f docker/Dockerfile -t jrc-conversas:sms-flux-20261027 .
```

Use a mesma imagem para os serviços web e worker. A migration `20261027180000_add_flux_to_sms_channels` adiciona os campos criptografados e permite remetente nulo para a Flux. Planeje backup e execução de `bundle exec rails db:migrate` antes de ativar a nova versão. Esta entrega não executa atualização em produção.

## Homologação pendente

A API respondeu com HTTPS e certificado verificado. A consulta autenticada realizada nesta sessão recebeu HTTP 200 com código de aplicação `901`, `IP NAO AUTORIZADO`. É necessário cadastrar na Flux o IP público de saída do servidor que realizará os envios. O IP do computador de desenvolvimento não substitui esse IP.

Depois da liberação, testar com um celular autorizado: envio, confirmação de entrega e resposta do cliente na mesma conversa. Essa homologação real não foi concluída; nenhum SMS real foi enviado nesta sessão. Confirmar também a habilitação de callback/MO e dos serviços escolhidos junto à Flux.

Base do contrato: manual Flux WebService e HTTP v2.7.2, envio JSON e callback; especificação técnica JRC fornecida para esta implementação.
