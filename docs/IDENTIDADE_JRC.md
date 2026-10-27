# Identidade visual JRC Conversas

O nome padrão da instalação é JRC Conversas. A apresentação usa os recursos originais já presentes em `public/brand-assets/`: `logo-jrc.png`, `logo-jrc-dark.png` e `logo-jrc-thumbnail.png`. Os favicons existentes também exibem JRC. Nenhum logotipo foi recriado.

`JrcBranding` resolve apenas os valores de apresentação padrão vindos de `GlobalConfig`, inclusive valores antigos em cache. Nomes, logotipos, URLs e a opção de ocultar a marca que já tenham sido personalizados são preservados. Não há migration de identidade visual nem regravação de configurações de clientes.

Os catálogos de tradução do dashboard, autenticação, widget e pesquisas recebem o nome de apresentação ao inicializar o Vue I18n. Apenas valores de texto são transformados; chaves, SDKs, URLs e namespaces permanecem intactos. Conversas, CRM, Service Desk, projetos, campanhas e demais módulos mantêm seus dados e funcionalidades e recebem essa apresentação comum quando usam os textos da aplicação.

Foram ajustados também textos auxiliares de configurações, notificações automáticas, e-mails, confirmação de cadastro, onboarding, pesquisa de satisfação, exemplos de campanhas, avatares padrão de automação e assinatura da retrospectiva. Os temas claro e escuro continuam usando seus recursos originais.

Referências técnicas permanecem necessárias: `Chatwoot`, `ChatwootApp`, `window.$chatwoot`, `chatwootSDK`, variáveis de ambiente, namespaces, rotas, dependências, identificadores de integração e migrations. Documentação, licenças e links técnicos do fornecedor não são renomeados. URLs de termos e privacidade já configuradas são preservadas; não foram inventados documentos jurídicos JRC.
