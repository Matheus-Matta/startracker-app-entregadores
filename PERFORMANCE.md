# Desempenho e organizacao do aplicativo

Este documento registra os principais pontos encontrados na revisao de codigo e
as decisoes aplicadas para reduzir rede, processamento e reconstrucoes de tela.

## Arquitetura aplicada

- `AppDependencies` e o ponto unico de composicao dos servicos. O aplicativo
  compartilha uma unica instancia de `ApiClient`, armazenamento de sessao e
  servicos com cache, em vez de recriar essa infraestrutura em cada tela.
- `AuthenticatedWebSocket` concentra autenticacao, renovacao de token,
  reconexao com backoff e encerramento. Os canais de frota e notificacoes ficam
  responsaveis somente por interpretar seus respectivos eventos.
- `api_collection.dart` concentra a leitura de respostas paginadas e elimina
  loops de paginacao duplicados nos servicos.
- `Debouncer` agrega eventos em tempo real que chegam em sequencia, evitando
  rajadas de requisicoes iguais.

## Otimizacoes implementadas

### Navegacao e ciclo de vida

- As cinco abas principais agora sao criadas sob demanda. Ao entrar no app,
  somente a aba inicial carrega dados.
- Abas inativas marcam seus dados como pendentes quando recebem um evento
  WebSocket e atualizam apenas quando voltam a ficar visiveis.
- O retorno de telas de detalhe reaproveita cache quando nao houve alteracao e
  invalida explicitamente o dado depois de uma operacao de escrita.

### Rede e cache

- Pedidos, waves, perfil e configuracao de entrega usam cache em memoria com
  invalidacao explicita.
- Requisicoes identicas em andamento sao compartilhadas, evitando chamadas
  concorrentes duplicadas.
- Cada cache tem uma geracao. Uma resposta antiga nao pode repopular o cache
  depois de uma atualizacao recebida via WebSocket.
- A listagem comum de pedidos solicita apenas a pagina exibida. A rota ativa
  solicita pedidos filtrados pela wave atual em vez de baixar todos os pedidos
  da conta.
- Rotas e waves independentes sao carregadas em paralelo.
- Tokens de sessao mantem um cache seguro em memoria para evitar leituras
  repetidas do armazenamento criptografado durante chamadas e reconexoes.

### Renderizacao

- Uma nova posicao de GPS move apenas o simbolo do motorista. A geometria da
  rota e redesenhada somente quando a rota ou a parada atual realmente muda.
- O campo de assinatura usa um `ValueNotifier` como sinal de pintura e nao
  reconstrui toda a pagina a cada ponto capturado.
- Atualizacoes WebSocket recarregam somente o dominio afetado (pedidos, rota ou
  perfil), em vez de recarregar toda a tela inicial.

## Regras de manutencao

- Operacoes que alteram dados devem invalidar o cache do respectivo servico.
- Eventos WebSocket nao devem executar chamadas de rede diretamente em uma aba
  inativa; devem marcar a aba como pendente.
- Novos canais WebSocket devem reutilizar `AuthenticatedWebSocket`.
- Novas colecoes paginadas devem reutilizar `getAllPages` quando a operacao
  realmente precisar do conjunto completo.
- Nao armazenar tokens ou segredos em `.env`; o arquivo contem apenas opcoes de
  build e caminhos publicos.

## Pontos restantes e proximas medicoes

- Busca textual e combinacoes de filtros de pedidos ainda percorrem todas as
  paginas para preservar o comportamento atual. Quando a API documentar esses
  filtros no servidor, essa leitura deve ser substituida por uma consulta
  paginada filtrada.
- O WebSocket entrega notificacoes enquanto o processo do app esta ativo. Para
  notificacoes com o app encerrado, o backend precisara integrar um provedor de
  push, como FCM/APNs.
- Antes de uma release, medir no Flutter DevTools o tempo de frame, memoria e
  volume de requisicoes em um roteiro real com muitas paradas. Esta revisao
  remove gargalos logicos; ela nao substitui uma medicao em aparelho de
  producao.

## Verificacao automatizada

Execute antes de publicar:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --release --dart-define-from-file=.env.production
```
