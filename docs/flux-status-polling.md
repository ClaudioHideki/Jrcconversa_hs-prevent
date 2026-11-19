# Flux: consulta automatica de status

Todos os novos SMS Flux aceitos pelo adaptador agendam consulta em 2 minutos.
Nao ha novos envios de SMS pelo job. Usa GET HTTPS /integracao3.do com type=C,
credenciais da caixa e id=flux_partner_id (ID do sistema de origem).
Manual v2.7.2: secoes 1.3-1.7, paginas 6-8; codigos HTTP na pagina 14.
Nao misturar esses codigos com a tabela de outro protocolo da pagina 23.

Consultas pendentes repetem a cada 5 minutos, no maximo 288 tentativas (~24h).
Trava Redis de 90 segundos por login Flux e ID coordena jobs e caixas desta
instalacao. Nao coordena servidores independentes. Consultas manuais externas
podem provocar 910; a tentativa e adiada sem inventar status.

120 com identidade e data de entrega validas -> delivered -> indicador Entregue
com dois riscos pelo mesmo fluxo de atualizacao ja existente.
146 -> NAO ENTREGUE; 130 -> BLOQUEADA; 138 -> EM ANALISE; 110 -> ENVIADA.
Outros codigos documentados sao mapeados explicitamente. 100, resposta vazia,
erro de API/rede, datas invalidas ou IDs divergentes preservam a pendencia.
Callbacks seguem ativos e usam o mesmo processador com locks, correlacao e
protecao contra duplicidades e regressao de estados finais.

Sem migracoes, alteracao de credenciais, modalidade, limites SMS ou outros canais.
So sao consultadas mensagens publicas de saida/template, sent, da caixa e conta
corretas. Entregues, lidas e falhas finais nao continuam consultando.
Ao esgotar as tentativas o estado e preservado, sem presumir falha ou entrega.
Nao faz varredura nem atualizacao automatica de mensagens historicas.
Reconciliacao historica exigira procedimento separado, com limite e aprovacao.
Nao ha publicacao de imagem ou deploy nesta etapa.
