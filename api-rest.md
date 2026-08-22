# API REST do Star Tracker: guia completo

Este documento é a referência única da API REST do Star Tracker. A API usa
Django REST Framework, é versionada sob `/api/v1/` e autentica clientes com JWT
no formato Bearer.

Rotas iniciadas por `/api/` aceitam qualquer hostname HTTP válido, inclusive
`10.0.2.2` no emulador Android. `ALLOWED_HOSTS` restringe somente portal, admin e
WebSockets. A API continua protegida por autenticação, permissões e rate limits.

O CORS é aplicado apenas a `/api/` e aceita as origens listadas em
`CORS_ALLOWED_ORIGINS`. Host e origem são conceitos diferentes: aplicativos
nativos não aplicam CORS; clientes executados em navegador devem cadastrar cada
origem permitida ou habilitar `CORS_ALLOW_ALL_ORIGINS` conscientemente.

## Fluxo geral

1. Obtenha os tokens informando usuário, senha e conta.
2. Envie o `access` em todas as requisições protegidas.
3. Acesse somente recursos autorizados para o perfil naquela conta.
4. Renove o `access` com o `refresh` quando necessário.
5. Faça um novo login para trabalhar em outra conta.

```mermaid
flowchart LR
    C[Cliente] -->|Login| J[JWT com account_id]
    J --> A[API v1]
    A --> T[Conta autorizada]
    T --> M[Módulo habilitado]
    M --> P[Permissão do perfil]
    P --> Q[Dados da conta]
```

## 1. Autenticação

### Login comum

`identifier` aceita username ou e-mail. `account_id` pode ser omitido somente
quando o usuário pertence a exatamente uma conta.

```http
POST /api/v1/auth/token/
Content-Type: application/json

{
  "identifier": "usuario@example.com",
  "password": "senha-segura",
  "account_id": 1
}
```

Resposta `200 OK`:

```json
{
  "access": "eyJ...",
  "refresh": "eyJ...",
  "token_type": "Bearer",
  "user": {"id": 10, "username": "usuario", "name": "Usuário Exemplo"},
  "account": {"id": 1, "name": "Conta Exemplo"}
}
```

Se o usuário possuir várias contas e não enviar `account_id`, a resposta
informa que a seleção é obrigatória e apresenta as contas autorizadas.

### Login exclusivo do entregador

Aplicativos de entrega devem usar:

```http
POST /api/v1/auth/entregadores/token/
Content-Type: application/json

{
  "identifier": "entregador@example.com",
  "password": "senha-segura",
  "account_id": 1
}
```

O token somente é emitido se o usuário estiver ativo, acessar a conta indicada
e possuir nela o perfil `delivery_driver` (Entregador). Um perfil de entregador
em outra conta não autoriza o login. Além dos campos do login comum, a resposta
inclui a política vigente de comprovantes:

```json
{
  "access": "eyJ...",
  "refresh": "eyJ...",
  "token_type": "Bearer",
  "user": {"id": 10, "username": "entregador", "name": "Entregador"},
  "account": {"id": 1, "name": "Conta Exemplo"},
  "delivery_config": {
    "version": 1,
    "require_photo": true,
    "minimum_photos": 1,
    "maximum_photos": 5,
    "require_signature": false,
    "require_recipient_name": true,
    "require_document": false,
    "require_note_on_failure": true,
    "capture_timestamp": true
  }
}
```

O aplicativo pode atualizar essa política sem refazer o login:

```http
GET /api/v1/auth/entregadores/configuracao/
Authorization: Bearer ACCESS_TOKEN
```

Resposta `200 OK`:

```json
{
  "delivery_config": {
    "version": 1,
    "require_photo": true,
    "minimum_photos": 1,
    "maximum_photos": 5,
    "require_signature": false,
    "require_recipient_name": true,
    "require_document": false,
    "require_note_on_failure": true,
    "capture_timestamp": true
  }
}
```

Campos da política:

| Campo | Tipo | Uso no aplicativo |
| --- | --- | --- |
| `version` | inteiro | Versão do contrato da política; atualmente `1` |
| `require_photo` | booleano | Exige foto para concluir a entrega |
| `minimum_photos` | inteiro | Quantidade mínima de fotos exigida |
| `maximum_photos` | inteiro | Quantidade máxima de fotos permitida |
| `require_signature` | booleano | Exige assinatura capturada no canvas |
| `require_recipient_name` | booleano | Exige o nome do recebedor |
| `require_document` | booleano | Exige CPF ou documento do recebedor |
| `require_note_on_failure` | booleano | Exige observação ao registrar ausência ou falha |
| `capture_timestamp` | booleano | Data e hora são registradas pelo servidor |
| `pickup_enabled` | booleano | A carga precisa ser conferida antes de ser roteirizada |
| `pickup_barcode_source` | texto | O que a etiqueta traz: `order_number` ou `external_id` |

Esse endpoint usa exclusivamente a conta do JWT, não aceita troca de tenant por
`account_id` e responde `403 Forbidden` se o usuário não possuir o perfil
Entregador nessa conta. `capture_timestamp` informa que a data e a hora são
registradas pelo servidor. A versão permite que o app reconheça futuras
alterações no contrato.

Respostas de erro:

| Status | Situação |
| --- | --- |
| `401 Unauthorized` | Token ausente, inválido, expirado ou sem conta válida |
| `403 Forbidden` | Usuário autenticado sem perfil Entregador na conta do JWT |

O token do Mapbox não faz parte desse payload. Ele continua sendo consultado
separadamente em `GET /api/v1/mapbox/`, permitindo sua troca ou revogação sem
exigir um novo login.

### Usar o access token

```http
GET /api/v1/auth/me/
Authorization: Bearer eyJ...
```

O endpoint retorna o usuário e a conta vinculada ao JWT. Nas demais chamadas,
use o mesmo header `Authorization`.

O claim `account_id` existe no access e no refresh. A API revalida se o usuário
continua ativo e vinculado à conta; remover o vínculo invalida o acesso mesmo
antes da expiração. Enviar outro `X-Account-ID` não troca o tenant.

### Obter a configuração Mapbox da conta

Use o access token para obter o token público efetivo do mapa. A API usa a
conta vinculada ao JWT e ignora qualquer `account_id` enviado pelo cliente.

```http
GET /api/v1/mapbox/
Authorization: Bearer eyJ...
```

```json
{
  "access_token": "pk.eyJ...",
  "token_source": "tenant",
  "available": true,
  "account": {"id": 1, "name": "Conta Exemplo"}
}
```

`token_source` pode ser `tenant`, `environment` ou `unavailable`. No aplicativo,
atribua `access_token` ao SDK do Mapbox antes de inicializar o mapa.

### Renovar ou verificar tokens

```http
POST /api/v1/auth/token/refresh/
Content-Type: application/json

{"refresh": "eyJ..."}
```

```http
POST /api/v1/auth/token/verify/
Content-Type: application/json

{"token": "eyJ..."}
```

Por padrão, o access dura 15 minutos e o refresh, 7 dias. Os valores usam
`JWT_ACCESS_MINUTES` e `JWT_REFRESH_DAYS`. A assinatura deriva de `SECRET_KEY`.

### WebSocket mobile autenticado

O aplicativo mobile usa o mesmo `access` JWT da API para abrir os canais em
tempo real:

| Canal | Endpoint |
| --- | --- |
| Frota, pedidos e rotas | `/ws/mobile/fleet/` |
| Notificações do usuário | `/ws/mobile/notifications/` |

Em produção use `wss://`; localmente pode ser usado `ws://`. O token deve ser
enviado no header do handshake e nunca na query string:

```http
GET /ws/mobile/fleet/ HTTP/1.1
Upgrade: websocket
Connection: Upgrade
Authorization: Bearer eyJ...
```

O servidor aceita somente access token assinado, não expirado, pertencente a um
usuário ativo e com acesso vigente à conta do claim `account_id`. A conta do
socket sempre vem do JWT; `?account_id=` não consegue trocá-la.

Ao conectar em `fleet`, a primeira mensagem confirma o tenant:

```json
{"type": "connected", "account_id": 1}
```

O canal pode enviar `vehicle_update`, `vehicle_batch`, `delivery_order_update`,
`delivery_order_remove`, `delivery_route_update`, `delivery_route_remove` e
`alert`. O canal de notificações envia `notification` e aceita:

```json
{"action": "mark_read", "id": 15}
```

```json
{"action": "mark_all_read"}
```

Token ausente, malformado, expirado ou de tipo refresh fecha a conexão com
`4401`. Conta removida ou não autorizada fecha com `4403`. Quando o access
expirar, renove-o via HTTP e abra uma nova conexão WebSocket.

### Notificações pessoais

As notificações são limitadas simultaneamente pelo `account_id` do JWT e pelo
usuário autenticado. Outro usuário da mesma conta não aparece na listagem nem
pode ter sua notificação marcada como lida por esse token.

| Método | Endpoint | Operação |
| --- | --- | --- |
| `GET` | `/api/v1/notificacoes/` | Lista as notificações do usuário |
| `GET` | `/api/v1/notificacoes/{id}/` | Consulta uma notificação própria |
| `POST` | `/api/v1/notificacoes/{id}/ler/` | Marca uma notificação própria como lida |
| `POST` | `/api/v1/notificacoes/ler-todas/` | Marca como lidas somente as notificações do usuário |

```json
{
  "id": 15,
  "kind": "wave_assigned",
  "title": "Uma wave foi atribuída a você",
  "message": "A wave #42 está disponível para atendimento.",
  "icon": "local_shipping",
  "level": "info",
  "url": "/app/minhas-entregas/",
  "data": {"wave_id": 42},
  "is_read": false,
  "read_at": null,
  "created_at": "2026-08-19T22:10:00-03:00"
}
```

| Tipo (`kind`) | Perfis destinatários |
| --- | --- |
| `general` | Todos os perfis |
| `vehicle_alert` e `geofence` | Administrador, gestor e operador |
| `maintenance` | Administrador, gestor e operador |
| `wave_assigned` | Somente o entregador atribuído à wave |

O canal `/ws/mobile/notifications/` usa o mesmo isolamento por usuário e conta.
Uma mensagem de outro usuário nunca entra no grupo WebSocket do token atual.

## 2. Conta, módulo e permissões

Toda operação combina três controles:

```text
conta do JWT + módulo ativo + permissão do perfil
```

Por exemplo, alterar um veículo exige `tracking.change_vehicle` no perfil e um
módulo habilitado que contenha essa permissão. Querysets, detalhes e relações
são limitados à conta do JWT. O cliente não escolhe o proprietário enviando o
campo `account`; a API o define pela autenticação.

Objetos de outra conta normalmente retornam `404`, evitando revelar sua
existência. Para mudar de conta, obtenha outro par de tokens com o `account_id`
desejado.

## 3. Padrão dos CRUDs

Para qualquer recurso registrado, como `veiculos`:

| Método | Endpoint | Operação |
| --- | --- | --- |
| `GET` | `/api/v1/veiculos/` | Listar |
| `POST` | `/api/v1/veiculos/` | Criar |
| `GET` | `/api/v1/veiculos/{id}/` | Consultar |
| `PUT` | `/api/v1/veiculos/{id}/` | Substituir |
| `PATCH` | `/api/v1/veiculos/{id}/` | Alterar parcialmente |
| `DELETE` | `/api/v1/veiculos/{id}/` | Excluir |

As listas têm 100 itens por página:

```json
{
  "count": 250,
  "next": "http://servidor/api/v1/veiculos/?page=2",
  "previous": null,
  "results": []
}
```

A raiz autenticada `GET /api/v1/` apresenta as rotas disponíveis no ambiente.
Os campos de cada payload podem ser consultados com uma requisição `OPTIONS`
ao endpoint.

`notificacoes` é a exceção ao CRUD genérico: permite somente leitura e as ações
`ler`/`ler-todas`; clientes não podem criar, alterar destinatário ou excluir
notificações.

## 4. Catálogo de recursos

Todos os nomes abaixo são relativos a `/api/v1/`.

| Domínio | Recursos |
| --- | --- |
| Ativos | `ativos`, `veiculos`, `celulares`, `rastreadores` |
| Operação | `posicoes`, `eventos`, `comandos`, `notificacoes` |
| Cercas | `cercas`, `atribuicoes-cerca` |
| Manutenção | `manutencoes`, `logs-manutencao`, `materiais-manutencao`, `servicos-manutencao` |
| Telemetria | `logs-telemetria`, `configuracoes-telemetria`, `leituras-telemetria` |
| Rastreadores | `fabricantes-rastreador`, `fornecedores-rastreador`, `modelos-rastreador`, `fornecedores-modelo`, `servidores-rastreador`, `templates-comando` |
| Acesso | `contas`, `usuarios`, `perfis-acesso`, `acessos-conta`, `modulos`, `modulos-conta`, `configuracao-mapa` |

Catálogos globais permitem leitura autorizada, mas somente superusuários podem
alterá-los. Excluir um usuário remove primeiro o vínculo com a conta atual; o
registro global só é apagado se não pertencer a outra conta e não for
superusuário. Segredos de mapa são somente escrita.

### Dados sensíveis

`tokens-servidor`, `requisicoes-rejeitadas`, `logs-seguranca` e
`nonces-webhook` exigem superusuário. `ServerToken.token` nunca volta na
resposta; somente seu fingerprint é apresentado.

## 5. Entregas de ponta a ponta

O módulo de entregas usa `/api/v1/delivery/`. Seu catálogo inclui
`configuracao`, `configuracoes-veiculo`, `entregadores`,
`vinculos-entregador-veiculo`, `turnos`, `jornadas`, `areas`, `armazens`,
`regras-distribuicao`, `pedidos`, `pedidos-wave`, `waves`, `otimizacoes`,
`nao-atribuidos`, `rotas`, `paradas`, `comprovantes`, `fotos-comprovante`,
`eventos` e `tentativas`.

### Turno e jornada são coisas diferentes

| Recurso | Modelo | O que é |
| --- | --- | --- |
| `turnos` | `WorkSchedule` | Horário reutilizável (“Comercial 08:00–17:00”, com almoço). Um mesmo turno atende vários entregadores; só decide **quem pode receber carga agora**. |
| `jornadas` | `DriverShift` | A operação em curso: entregador, veículo, posição inicial e capacidade. É o que o roteirizador consome como veículo. |

> **Mudança em relação à versão anterior:** `delivery/turnos` apontava para
> `DriverShift`. Esse recurso agora responde em `delivery/jornadas`, e
> `delivery/turnos` passou a ser o horário reutilizável. Clientes que criavam
> jornadas precisam trocar a URL.

Campos de `turnos`:

| Campo | Tipo | Descrição |
| --- | --- | --- |
| `name` | texto | Nome do turno; único por conta |
| `active` | booleano | Turno desativado vale como turno nenhum |
| `start_time` | hora `HH:MM` | Início do expediente |
| `lunch_start` | hora ou `null` | Início do almoço; opcional, mas exige `lunch_end` junto |
| `lunch_end` | hora ou `null` | Fim do almoço |
| `end_time` | hora `HH:MM` | Fim do expediente |

`end_time` menor que `start_time` descreve um turno noturno que vira a
meia-noite (ex.: `22:00`–`06:00`). O almoço precisa cair dentro do expediente.

Um entregador só enxerga o turno ao qual está vinculado; perfis
administrativos listam todos os turnos da conta.

### Turno e disponibilidade do entregador

O recurso `entregadores` ganhou dois campos graváveis e três de leitura:

| Campo | Tipo | Descrição |
| --- | --- | --- |
| `work_schedule` | inteiro ou `null` | Turno vinculado; `null` significa elegível a qualquer hora |
| `availability` | texto | `available`, `busy` ou `offline` |
| `schedule` | objeto ou `null` (leitura) | O turno vinculado já expandido, para o app não precisar de uma segunda chamada |
| `availability_label` | texto (leitura) | Rótulo pronto para exibir: `Disponível`, `Ocupado` ou `Desconectado` |
| `is_on_duty` | booleano (leitura) | Se está em horário de trabalho **agora** |

`is_on_duty` não é o mesmo que estar livre: quem está numa rota continua em
horário, só que `busy`. Sem turno vinculado ele é sempre `true`.

```json
{
  "id": 7,
  "user": 10,
  "availability": "available",
  "availability_label": "Disponível",
  "is_on_duty": true,
  "work_schedule": 3,
  "schedule": {
    "id": 3,
    "name": "Comercial",
    "active": true,
    "start_time": "08:00:00",
    "lunch_start": "12:00:00",
    "lunch_end": "13:00:00",
    "end_time": "17:00:00"
  }
}
```

`availability` muda sozinho nas pontas da operação: iniciar uma rota marca o
entregador como `busy`, e concluí-la devolve para `available`. Quem foi posto
em `offline` manualmente não é reativado pelo fim de uma rota.

#### Alterar só a disponibilidade

Para não reenviar o cadastro inteiro só para dizer "estou de volta":

```http
POST /api/v1/delivery/entregadores/7/disponibilidade/
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{"availability": "offline"}
```

A resposta `200 OK` traz o entregador já atualizado. Um valor fora de
`available`/`busy`/`offline` responde `400`.

Quem pode chamar:

| Quem | Pode alterar |
| --- | --- |
| Entregador | Apenas a própria disponibilidade — o escopo do perfil já esconde os colegas, então o id de outro entregador responde `404` |
| Perfis com `delivery.change_driverprofile` | A de qualquer entregador da conta |

### Regra de horário na distribuição de carga

Antes de incluir um entregador numa carga, o servidor avalia o turno dele:

| Situação | Recebe carga? |
| --- | --- |
| Sem turno vinculado (ou turno inativo) | Sim — regra 24/7 |
| Dentro do expediente | Sim |
| Dentro do intervalo de almoço | Não |
| Fora do expediente | Não |

A verificação acontece no backend, em `available_shifts()`, que é o ponto por
onde passa toda distribuição automática — não é validação só de tela. Uma wave
com jornada fixada manualmente pelo operador continua honrando essa escolha.

Itens e volumes não possuem endpoints CRUD independentes. Eles são
sub-recursos aninhados no payload de `pedidos` e sempre respeitam a conta do
pedido.

### Modelo de pedido, item e volume

| Modelo | Responsabilidade | Relação |
| --- | --- | --- |
| `DeliveryOrder` | Pedido, endereço, prioridade, janela, coordenadas e totais da carga | Pertence à conta e pode possuir vários itens |
| `DeliveryOrderItem` | Produto ou conjunto lógico, como “Guarda-roupa” | Pertence a um pedido; exclusão do pedido remove seus itens |
| `DeliveryOrderItemVolume` | Pacote físico com dimensões e peso próprios | Pertence a um item; cada volume representa uma unidade física |

Cada item carrega seu próprio resultado de entrega, resolvido na conclusão da
parada (veja [Entrega parcial por item](#entrega-parcial-por-item)):

| Campo | Tipo | Descrição |
| --- | --- | --- |
| `status` | texto (somente leitura) | `pending`, `delivered` ou `failed` |
| `failure_reason` | texto (somente leitura) | Motivo quando `status` é `failed` |
| `failure_notes` | texto (somente leitura) | Observação registrada junto do motivo |

Esses três campos são calculados pelo servidor a partir de `POST
paradas/{id}/complete/` ou `POST paradas/{id}/fail/` e não podem ser enviados
na criação ou atualização do pedido.

Os principais campos de `DeliveryOrder` são:

| Grupo | Campos |
| --- | --- |
| Identificação | `id`, `order_number`, `external_source`, `external_id` |
| Cliente | `customer_name`, `customer_phone` |
| Origem | `warehouse` |
| Endereço | `address`, `address_number`, `address_complement`, `neighborhood`, `city`, `state`, `postal_code` |
| Coordenadas | `lat`, `lon` |
| Carga agregada | `volume` em cm³, `weight` em gramas e `units` |
| Planejamento | `priority`, `effective_priority`, `skills`, `service_duration_seconds`, `delivery_window_start`, `delivery_window_end`, `ready_at`, `promised_at` |
| Operação | `status`, `delivery_area`, `unassigned_reason`, `proof_overrides` |
| Auditoria | `created_at`, `updated_at` |

`account` é definido pelo JWT e é somente leitura. Relacionamentos como
`warehouse` e `delivery_area` precisam pertencer à mesma conta.

Quando o pedido possui volumes, os agregados são calculados pelo servidor:

```text
volume = soma(length_cm × width_cm × height_cm)
weight = soma(weight_g)
units = quantidade de volumes
```

Um item pode conter vários volumes. Pedido sem itemização mantém os valores
agregados enviados diretamente em `volume`, `weight` e `units`, preservando a
compatibilidade com integrações OMS antigas.

### Criar um pedido com itens

```http
POST /api/v1/delivery/pedidos/
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{
  "order_number": "PED-2026-001",
  "external_source": "erp",
  "external_id": "987654",
  "customer_name": "Cliente Exemplo",
  "customer_phone": "(21) 99999-0000",
  "warehouse": 1,
  "address": "Estrada dos Menezes",
  "address_number": "300",
  "address_complement": "Casa 2",
  "neighborhood": "Colubandê",
  "city": "São Gonçalo",
  "state": "RJ",
  "postal_code": "24451-230",
  "priority": 30,
  "service_duration_seconds": 300,
  "items": [
    {
      "name": "Guarda-roupa",
      "volumes": [
        {
          "length_cm": 100,
          "width_cm": 50,
          "height_cm": 20,
          "weight_g": 8000
        },
        {
          "length_cm": 60,
          "width_cm": 40,
          "height_cm": 10,
          "weight_g": 3000
        }
      ]
    }
  ]
}
```

A resposta inclui os IDs gerados e os totais recalculados:

```json
{
  "id": 81,
  "order_number": "PED-2026-001",
  "volume": 124000,
  "weight": 11000,
  "units": 2,
  "items": [
    {
      "id": 15,
      "name": "Guarda-roupa",
      "volumes": [
        {
          "id": 31,
          "length_cm": 100.0,
          "width_cm": 50.0,
          "height_cm": 20.0,
          "weight_g": 8000
        },
        {
          "id": 32,
          "length_cm": 60.0,
          "width_cm": 40.0,
          "height_cm": 10.0,
          "weight_g": 3000
        }
      ]
    }
  ]
}
```

Em `PUT` ou `PATCH`, enviar `items` substitui toda a coleção anterior de itens
e volumes. Omitir `items` preserva a coleção atual. Os IDs aninhados são
gerados pelo servidor; a alteração não é incremental por ID.

Dimensões usam centímetros e aceitam zero ou valores positivos. `weight_g` é
um inteiro não negativo. Na importação OMS, todo item informado deve possuir
nome e ao menos um volume.

### Importação OMS idempotente

```http
POST /api/v1/delivery/pedidos/import/
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{
  "source": "erp",
  "orders": [
    {
      "external_id": "987654",
      "order_number": "PED-2026-001",
      "customer_name": "Cliente Exemplo",
      "warehouse_id": 1,
      "address": "Estrada dos Menezes",
      "address_number": "300",
      "neighborhood": "Colubandê",
      "city": "São Gonçalo",
      "state": "RJ",
      "postal_code": "24451-230",
      "items": [
        {
          "name": "Caixa",
          "volumes": [
            {
              "length_cm": 40,
              "width_cm": 30,
              "height_cm": 20,
              "weight_g": 2500
            }
          ]
        }
      ]
    }
  ]
}
```

`orders` precisa ser uma lista não vazia e cada entrada exige `external_id`.
A combinação da conta, `source` e `external_id` cria ou atualiza o mesmo pedido.
`warehouse_id` e `warehouse` são aceitos como referência do armazém. Quando
`items` é omitido, a itemização existente é preservada; quando enviado, o
conjunto é substituído. A resposta é `200 OK` com uma lista de pedidos, sem o
envelope de paginação.

### Geocodificação do pedido

```http
POST /api/v1/delivery/pedidos/81/geocode/
Authorization: Bearer ACCESS_TOKEN
```

A consulta exige logradouro, número, bairro, cidade, UF e CEP. O endereço é
enviado como:

```text
Estrada dos Menezes, 300 - Colubandê, São Gonçalo - RJ, 24451-230, Brasil
```

Com uma chave Google disponível, `ROOFTOP` é aceito como posição exata.
`RANGE_INTERPOLATED` é aceito somente quando não é uma correspondência parcial
e confirma logradouro, número, cidade, UF e país; nesse caso a coordenada é
marcada como estimada. O CEP continua sendo enviado ao Google, mas uma
divergência apenas gera um aviso e não descarta latitude e longitude quando os
demais componentes conferem. `APPROXIMATE`, `GEOMETRIC_CENTER` e divergências
no endereço validado são rejeitados. Em erro, a API responde `400`, limpa as
coordenadas e os metadados anteriores e mantém o pedido em `awaiting_geocode`
com `unassigned_reason` igual a `geocode_failed`.

A representação do pedido informa a origem e a qualidade da coordenada:

```json
{
  "lat": -22.8419,
  "lon": -43.0842,
  "geocode_provider": "google",
  "geocode_location_type": "RANGE_INTERPOLATED",
  "geocode_is_estimated": true
}
```

Os campos `geocode_*` são somente leitura. Para Google, o tipo será `ROOFTOP`
ou `RANGE_INTERPOLATED`; no fallback ele será `NOMINATIM` e a coordenada também
será marcada como estimada.

Na simulação local, `simulate_delivery_operation` não utiliza latitude ou
longitude predefinidas nos pedidos demonstrativos. O comando limpa esses campos,
ignora o cache e aguarda uma nova resposta síncrona para cada endereço. O log do
terminal informa quando a consulta usa Google Maps ou Nominatim e mostra as
coordenadas retornadas. O fallback para Nominatim só ocorre em falha técnica do
Google. `RANGE_INTERPOLATED` validado é aceito como estimado; `APPROXIMATE`,
`GEOMETRIC_CENTER` e resultados divergentes continuam sendo rejeitados.

O comando não delega essa etapa ao Celery, pois precisa bloquear o início da
operação até todas as coordenadas estarem disponíveis. Ele considera pedidos da
seed e pedidos do `counter-sales-simulator` vinculados a waves ou rotas
operacionais. Se não houver candidatos, o terminal registra que nenhuma
consulta foi necessária. Depois dessa preparação, aguarda por padrão cinco
segundos entre cada ação operacional; `--interval-seconds` permite controlar
esse ritmo. O `simulate_counter_sales` também cria pedidos sem
`lat` e `lon` predefinidos, deixando esses campos a cargo da geocodificação. O
catálogo do comando usa somente endereços previamente conferidos sem
`partial_match`; divergência apenas de CEP segue a política de aviso e não
descarta as coordenadas. Os pedidos sintéticos podem conter de um a quatro itens
de autopeças, com volumes, dimensões e pesos próprios, sempre sem `lat` e `lon`
predefinidos.

### Roteirizar a própria wave como entregador

O perfil Entregador possui `view_deliverywave` e a permissão dedicada
`prepare_deliverywave`, mas não recebe `change_deliverywave`. Assim, ele pode
consultar waves atribuídas ao seu `DriverProfile` em qualquer estado sem obter
acesso às alterações administrativas do recurso:

```http
GET /api/v1/delivery/waves/?page=1
Authorization: Bearer ACCESS_TOKEN
```

O queryset usa simultaneamente a conta do JWT e o entregador autenticado. Waves
de outro entregador não aparecem na lista e retornam `404` no detalhe.

Para uma wave própria em `ready`, use a ação atômica:

```http
POST /api/v1/delivery/waves/10/prepare-route/
Authorization: Bearer ACCESS_TOKEN
```

A ação não recebe payload e executa, em sequência:

1. confirma que a wave pertence ao entregador autenticado;
2. confirma o estado `ready` e um turno válido do mesmo entregador;
3. executa `DeliveryRoutingService.optimize()`;
4. exige que a otimização gere uma única rota para esse entregador;
5. altera a rota de `planned` para `released`;
6. altera a wave para `released` e preenche `released_at`.

Resposta `200 OK`:

```json
{
  "wave_id": 10,
  "status": "released",
  "route_id": 25,
  "route_number": "ROTA-25"
}
```

Wave própria que não esteja em `ready`, ausência de turno elegível ou falha do
roteirizador retorna `400`. Uma wave de outro entregador permanece invisível e
retorna `404`. A permissão dedicada não autoriza `PUT`, `PATCH`, `DELETE` nem as
ações administrativas `optimize`, `release`, `close` e `cancel`.

### Retirada da carga (conferência por código de barras)

Com `pickup_enabled` ligado na configuração da conta, **a wave só pode ser
roteirizada depois que todos os pedidos dela forem retirados** — ou removidos
da carga. A conferência é feita lendo a etiqueta de cada pedido.

O que a etiqueta traz vem de `pickup_barcode_source`:

| Valor | Código impresso e lido |
| --- | --- |
| `order_number` (padrão) | `DeliveryOrder.order_number` |
| `external_id` | `DeliveryOrder.external_id`; pedido sem código externo cai no número do pedido, para a etiqueta nunca sair em branco |

#### Consultar o progresso

```http
GET /api/v1/delivery/waves/10/retirada/
Authorization: Bearer ACCESS_TOKEN
```

```json
{
  "wave_id": 10,
  "pickup_enabled": true,
  "barcode_source": "order_number",
  "total": 3,
  "picked_up": 1,
  "pending": 2,
  "is_complete": false,
  "orders": [
    {
      "order_id": 81,
      "order_number": "PED-2026-001",
      "customer": "Cliente Exemplo",
      "code": "PED-2026-001",
      "picked_up_at": "2026-08-22T09:14:00-03:00"
    }
  ]
}
```

#### Registrar a retirada

O app manda o que a câmera leu; o portal manda o que foi digitado — é o mesmo
endpoint. A resposta é o mesmo payload de progresso, já atualizado.

```http
POST /api/v1/delivery/waves/10/retirada/
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{"code": "PED-2026-001"}
```

O código é comparado ignorando maiúsculas e espaços, porque leitor de mão e
digitação manual chegam com formatações diferentes.

| Status | Situação |
| --- | --- |
| `400` | Código vazio, não corresponde a nenhum pedido da carga, ou pedido já retirado |
| `403` | Usuário não é o entregador da carga nem tem `delivery.change_deliverywave` |
| `404` | Wave fora da conta do JWT ou de outro entregador |

Quem pode registrar: o entregador dono da carga (conferindo o que vai levar) e
quem tem `delivery.change_deliverywave` (o conferente do armazém).

#### Efeito na roteirização

Enquanto faltar pedido, `POST waves/{id}/optimize/` e
`waves/{id}/prepare-route/` respondem `400` com a contagem do que falta:

```json
["A carga ainda não foi retirada por completo: 2 de 3 pedido(s) aguardando conferência."]
```

A trava vive no serviço de roteirização, não só no botão do portal — vale
igual para API, tarefa periódica e simulador. Remover o pedido da carga também
libera: o que saiu da wave deixa de ser cobrado na conferência.

A retirada é gravada no vínculo `WaveOrder`, não no pedido. Tirar o pedido da
carga apaga a conferência junto — na carga seguinte ele precisa ser bipado de
novo.

### Assinatura, fotos e conclusão da entrega

Assinatura e fotos são enviadas como `multipart/form-data`, não como JSON ou
Base64. O fluxo usa três etapas:

1. criar o comprovante da parada e enviar a assinatura;
2. enviar cada foto vinculada ao ID do comprovante;
3. concluir a parada, que também marca o pedido como entregue.

As listagens e consultas do perfil Entregador são limitadas aos comprovantes de
suas próprias rotas. Todos os IDs relacionados precisam pertencer à conta do
JWT. O campo `account` nunca deve ser enviado.

#### 1. Criar o comprovante e enviar a assinatura

```http
POST /api/v1/delivery/comprovantes/
Authorization: Bearer ACCESS_TOKEN
Content-Type: multipart/form-data
```

Campos aceitos:

| Campo | Tipo | Descrição |
| --- | --- | --- |
| `route_stop` | inteiro | ID da parada que será concluída; obrigatório na criação |
| `recipient_name` | texto | Nome de quem recebeu a entrega |
| `recipient_document` | texto | Documento do recebedor, quando exigido |
| `signature_file` | arquivo | Imagem da assinatura |
| `lat` | decimal | Latitude onde o comprovante foi coletado |
| `lon` | decimal | Longitude onde o comprovante foi coletado |
| `notes` | texto | Observações da entrega |

Exemplo com `curl`:

```bash
curl -X POST "https://servidor/api/v1/delivery/comprovantes/" \
  -H "Authorization: Bearer ACCESS_TOKEN" \
  -F "route_stop=42" \
  -F "recipient_name=Maria da Silva" \
  -F "recipient_document=12345678900" \
  -F "lat=-22.9064" \
  -F "lon=-43.1752" \
  -F "notes=Recebido na portaria" \
  -F "signature_file=@assinatura.png;type=image/png"
```

Resposta `201 Created`, abreviada:

```json
{
  "id": 12,
  "account": 1,
  "route_stop": 42,
  "recipient_name": "Maria da Silva",
  "recipient_document": "12345678900",
  "signature_file": "https://servidor/media/delivery/signatures/2026/08/assinatura.png",
  "lat": -22.9064,
  "lon": -43.1752,
  "completed_at": null,
  "notes": "Recebido na portaria",
  "items": []
}
```

`items` lista os IDs de `DeliveryOrderItem` cobertos por este comprovante —
isto é, os itens que efetivamente saíram nesta visita. O servidor a preenche
ao concluir a parada (veja [Entrega parcial por item](#entrega-parcial-por-item));
não a envie manualmente. `items` e `completed_at` são campos somente leitura;
se um cliente antigo ainda os enviar na criação ou atualização do comprovante,
eles serão ignorados e nunca anteciparão a conclusão.

Existe somente um `DeliveryProof` por parada. Se o comprovante já existir,
atualize seus dados ou substitua a assinatura usando o ID retornado:

```bash
curl -X PATCH "https://servidor/api/v1/delivery/comprovantes/12/" \
  -H "Authorization: Bearer ACCESS_TOKEN" \
  -F "recipient_name=Maria da Silva" \
  -F "signature_file=@assinatura-corrigida.png;type=image/png"
```

Em aplicações que capturam a assinatura em um `<canvas>`, converta o conteúdo
para `Blob`/`File`, dê um nome com extensão permitida — por exemplo,
`assinatura.png` — e envie esse arquivo no campo `signature_file`. A API não
recebe o Data URL do canvas diretamente.

Não envie `completed_at`: esse campo é preenchido pelo servidor somente depois
que a parada for concluída com sucesso.

#### 2. Enviar as fotos

Cada foto é enviada em uma requisição própria para
`fotos-comprovante`. Use em `delivery_proof` o ID recebido na etapa anterior e
uma sequência única dentro desse comprovante.

```http
POST /api/v1/delivery/fotos-comprovante/
Authorization: Bearer ACCESS_TOKEN
Content-Type: multipart/form-data
```

```bash
curl -X POST "https://servidor/api/v1/delivery/fotos-comprovante/" \
  -H "Authorization: Bearer ACCESS_TOKEN" \
  -F "delivery_proof=12" \
  -F "sequence=1" \
  -F "file=@foto-entrega-1.jpg;type=image/jpeg"
```

Para uma segunda foto:

```bash
curl -X POST "https://servidor/api/v1/delivery/fotos-comprovante/" \
  -H "Authorization: Bearer ACCESS_TOKEN" \
  -F "delivery_proof=12" \
  -F "sequence=2" \
  -F "file=@foto-entrega-2.jpg;type=image/jpeg"
```

Resposta `201 Created`:

```json
{
  "id": 30,
  "account": 1,
  "delivery_proof": 12,
  "file": "https://servidor/media/delivery/photos/2026/08/foto-entrega-1.jpg",
  "sequence": 1,
  "created_at": "2026-08-21T10:30:00-03:00"
}
```

Assinatura e fotos aceitam arquivos `.jpg`, `.jpeg`, `.png` e `.webp`, com no
máximo 10 MB por arquivo. A quantidade máxima de fotos vem de
`DeliveryConfig.maximum_photos` ou de `order.proof_overrides.maximum_photos`.
A combinação `delivery_proof` + `sequence` não pode se repetir.

#### 3. Finalizar a parada e o pedido

Depois de persistir todos os dados exigidos, conclua a mesma parada usada em
`route_stop`:

```bash
curl -X POST "https://servidor/api/v1/delivery/paradas/42/complete/" \
  -H "Authorization: Bearer ACCESS_TOKEN"
```

Essa chamada não recebe assinatura ou fotos — apenas, opcionalmente, o
resultado por item (veja [Entrega parcial por item](#entrega-parcial-por-item)
logo abaixo). Antes de concluir, o servidor consulta `DeliveryConfig` e os
valores opcionais de `order.proof_overrides` e valida:

- existência do comprovante;
- quantidade mínima de fotos, quando `require_photo` estiver ativo;
- assinatura, quando `require_signature` estiver ativo;
- nome do recebedor, quando `require_recipient_name` estiver ativo;
- documento, quando `require_document` estiver ativo;
- observação de cada item marcado como `failed`, quando `require_note_on_failure`
  estiver ativo.

As chaves aceitas em `proof_overrides` são `require_photo`, `minimum_photos`,
`maximum_photos`, `require_signature`, `require_recipient_name`,
`require_document` e `require_note_on_failure`. Para cada chave, um valor não
nulo no pedido tem prioridade sobre `delivery_config`; uma chave ausente ou com
valor `null` herda a política da conta. Portanto, `false` e `0` são overrides
válidos. `capture_timestamp` é uma regra global e não pode ser sobrescrita pelo
pedido.

Exemplo recebido em um pedido:

```json
{
  "id": 42,
  "order_number": "PED-2026-0042",
  "proof_overrides": {
    "require_photo": true,
    "minimum_photos": 2,
    "maximum_photos": 4,
    "require_signature": true,
    "require_recipient_name": true,
    "require_document": true,
    "require_note_on_failure": true
  }
}
```

O aplicativo deve calcular cada chave desta forma:

```text
configuração efetiva = proof_overrides[chave] ?? delivery_config[chave]
```

Não substitua o objeto inteiro: combine chave por chave. Assim, um pedido pode
exigir assinatura sem perder os limites de fotos definidos pela conta. Chaves
desconhecidas são ignoradas pelo backend.

Perfis administrativos com a permissão correspondente podem consultar a
configuração administrativa completa em `GET /api/v1/delivery/configuracao/`.
O Entregador consulta somente a política segura destinada ao app em
`GET /api/v1/auth/entregadores/configuracao/`. Por padrão, contas novas exigem um
comprovante, nome do recebedor e ao menos uma foto; assinatura e documento
começam como opcionais. O fluxo operacional esperado antes do comprovante é
registrar `POST paradas/{id}/arrive/` e `POST paradas/{id}/begin/`.

Quando a validação passa, a API:

- altera a parada para `completed`;
- altera o pedido para `delivered`, `partially_delivered` ou `delivery_failed`,
  conforme o resultado de seus itens (veja abaixo);
- vincula ao comprovante os itens efetivamente entregues;
- preenche `DeliveryProof.completed_at`;
- recalcula o trajeto restante ou encerra a rota e a wave quando não houver
  outras paradas pendentes.

Se faltar algum requisito, a resposta será `400 Bad Request`, por exemplo:

```json
[
  "São necessárias pelo menos 2 fotos",
  "Assinatura obrigatória"
]
```

O comprovante permanece salvo e pode ser corrigido com `PATCH` ou receber novas
fotos antes de repetir `POST paradas/{id}/complete/`.

#### Entrega parcial por item

Um pedido com vários itens pode ter uma entrega parcial — por exemplo, o
entregador leva dois produtos e só um chega ao destinatário. `POST
paradas/{id}/complete/` aceita um corpo JSON opcional descrevendo o resultado
de cada item:

```http
POST /api/v1/delivery/paradas/42/complete/
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{
  "items": [
    {"id": 15, "status": "delivered"},
    {
      "id": 16,
      "status": "failed",
      "reason": "recipient_absent",
      "notes": "Cliente não estava para receber o segundo volume"
    }
  ]
}
```

| Campo (por item) | Tipo | Descrição |
| --- | --- | --- |
| `id` | inteiro | ID do `DeliveryOrderItem`; itens de outro pedido são ignorados |
| `status` | texto | `delivered` ou `failed`; qualquer outro valor é tratado como `delivered` |
| `reason` | texto | Motivo da falha; aceita os mesmos códigos de `paradas/{id}/fail/` |
| `notes` | texto | Observação da falha; obrigatória quando `require_note_on_failure` estiver ativo |

Regras:

- omitir `items`, enviar lista vazia ou omitir um item da lista marca esse
  item (ou todos, se `items` não vier) como `delivered` — pedidos sem
  itens cadastrados continuam funcionando exatamente como antes deste
  recurso, sem enviar nada;
- todo item `delivered` entra em `DeliveryProof.items`; nenhum item `failed`
  entra lá — o motivo e a observação da falha ficam no próprio item
  (`DeliveryOrderItem.failure_reason`/`failure_notes`), não no comprovante;
- o pedido muda para `delivered` quando todo item foi entregue (ou o pedido
  não tem itens cadastrados), `delivery_failed` quando nenhum item foi
  entregue, e `partially_delivered` quando o resultado for misto.

Uma falha total da parada — o entregador não conseguiu entregar nada, sem
comprovante — continua usando `POST paradas/{id}/fail/` (sem relação com
`items`); nesse caso todos os itens do pedido também são marcados `failed` com
o mesmo motivo e observação da parada.

### Próxima entrega: adiar uma parada

Quando o entregador prefere deixar uma entrega para depois — cliente não
atende agora, rua interditada, prefere fechar o quarteirão primeiro — sem
cancelar nem registrar falha:

```http
POST /api/v1/delivery/paradas/42/skip/
Authorization: Bearer ACCESS_TOKEN
```

A chamada não recebe payload. A parada vai para o **fim das paradas pendentes**
e a resposta `200 OK` traz a parada já com a nova `sequence`.

Numa rota `A B C D E` com `A` concluída, adiar `B` resulta em:

```text
antes:   1 A✓   2 B    3 C    4 D    5 E
depois:  1 A✓   2 C    3 D    4 E    5 B
```

As pendentes apenas permutam entre as posições que já ocupavam, então uma
parada concluída mantém a sequência que teve na execução e o histórico da rota
continua legível.

O que **não** muda:

- o pedido continua pendente — não vira `delivery_failed` nem gera
  `DeliveryAttempt`; adiar não é falha;
- paradas concluídas, comprovantes e a ordem já executada ficam intactos;
- o otimizador **não** roda de novo: nenhuma `OptimizationRun` é criada e a
  wave inteira não é reprocessada. Só o trecho restante do trajeto é
  recalculado, o mesmo recálculo que já acontece ao concluir uma parada.

Se a parada estava em `arrived` ou `delivering`, ela volta para `planned` — é
de novo uma entrega por fazer. O `actual_arrival` continua gravado: a visita
aconteceu de verdade e o histórico não se apaga.

O mapa e o app recebem a nova ordem pelo `order_ids` do trajeto da rota, que
acompanha a sequência das paradas.

Respostas de erro:

| Status | Situação |
| --- | --- |
| `400` | A parada já foi encerrada, ou é a última pendente e não há outra para assumir a vez |
| `404` | Parada de outro entregador ou fora da conta do JWT |

> `skip/` não é o estado `skipped` da parada. Aquele encerra a parada e tira o
> pedido da rota; este só troca a ordem, mantendo a entrega pendente.

### Endpoints e ações do delivery

| Recurso | Ações adicionais ao CRUD |
| --- | --- |
| `entregadores` | `POST entregadores/{id}/disponibilidade/` |
| `waves` | `GET`/`POST waves/{id}/retirada/` para a conferência da carga |
| `pedidos` | `POST pedidos/import/`, `POST pedidos/{id}/geocode/` |
| `waves` | `POST waves/{id}/prepare-route/` para o dono; `optimize/`, `release/`, `close/`, `cancel/` para perfis administrativos |
| `rotas` | `POST rotas/{id}/accept/`, `start/`, `release/`, `lock/`, `unlock/`, `cancel/` |
| `paradas` | `POST paradas/{id}/arrive/`, `begin/`, `complete/`, `fail/`, `skip/` |
| `comprovantes` | CRUD com validação de conta e parada |
| `fotos-comprovante` | CRUD e upload associado ao comprovante |

### Estados operacionais

| Modelo | Valores de `status` |
| --- | --- |
| Pedido | `created`, `awaiting_geocode`, `outside_delivery_area`, `waiting_wave`, `ready_for_routing`, `routing`, `awaiting_pickup`, `routed`, `released`, `out_for_delivery`, `delivered`, `partially_delivered`, `delivery_failed`, `routing_failed`, `returned`, `cancelled` |
| Item do pedido | `pending`, `delivered`, `failed` |
| Entregador (`availability`) | `available`, `busy`, `offline` |
| Wave | `collecting`, `ready`, `optimizing`, `planned`, `released`, `closed`, `cancelled`, `failed`, `completed`, `partially_completed` |
| Rota | `planned`, `released`, `accepted`, `started`, `completed`, `partially_completed`, `cancelled`, `superseded` |
| Parada | `planned`, `approaching`, `arrived`, `delivering`, `completed`, `failed`, `skipped`, `cancelled` |

### Fluxo administrativo

1. Cadastre ou importe pedidos com `POST delivery/pedidos/` ou
   `POST delivery/pedidos/import/`.
2. Se necessário, geocodifique um pedido com
   `POST delivery/pedidos/{id}/geocode/`.
3. Cadastre entregadores, veículos, vínculos, turnos, áreas e regras.
4. Crie uma wave e associe seus pedidos.
5. Execute `POST delivery/waves/{id}/optimize/` para gerar as rotas.
6. Confira `delivery/otimizacoes/` e `delivery/nao-atribuidos/`.
7. Libere a wave com `POST delivery/waves/{id}/release/`.
8. Ao final, use `POST delivery/waves/{id}/close/` quando aplicável.

Waves também aceitam `POST .../{id}/cancel/`. Rotas administrativas aceitam
`release`, `lock`, `unlock` e `cancel` no mesmo padrão de URL.

### Fluxo do entregador

1. Faça login em `/api/v1/auth/entregadores/token/`.
2. Liste as waves próprias em `GET delivery/waves/`.
3. Para uma wave `ready`, use `POST delivery/waves/{id}/prepare-route/` e abra
   a rota indicada por `route_id` na resposta.
4. Liste as rotas em `GET delivery/rotas/` quando precisar sincronizar o estado.
5. A rota já estará `released`; aceite-a opcionalmente com
   `POST delivery/rotas/{id}/accept/` ou inicie com `POST .../{id}/start/`.
6. Ao chegar, envie `POST delivery/paradas/{id}/arrive/`. Para deixar essa
   entrega para o fim do roteiro, use
   [`POST delivery/paradas/{id}/skip/`](#próxima-entrega-adiar-uma-parada).
7. Inicie o atendimento com `POST delivery/paradas/{id}/begin/`.
8. Crie o comprovante, envie a assinatura e depois cada foto conforme o fluxo
   de [assinatura, fotos e conclusão da entrega](#assinatura-fotos-e-conclusão-da-entrega).
9. Conclua com `POST delivery/paradas/{id}/complete/` ou informe falha:

```http
POST /api/v1/delivery/paradas/42/fail/
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{
  "reason": "destinatario_ausente",
  "notes": "Nova tentativa solicitada",
  "lat": -23.5505,
  "lon": -46.6333
}
```

As transições de estado e exigências de prova são validadas pelo servidor.
Consulte [Entregas e roteirização](delivery.md) para regras operacionais,
configuração do ORS/VROOM e estados do domínio.

## 6. Assets estáticos e modelos 3D

| Operação | Endpoint |
| --- | --- |
| Listar | `GET /api/v1/assets/` |
| Filtrar 3D | `GET /api/v1/assets/?kind=3d` |
| Consultar | `GET /api/v1/assets/3d/carro.glb/` |
| Baixar | `GET /api/v1/assets/3d/carro.glb/?download=1` |
| Enviar | `POST /api/v1/assets/` com multipart `path` e `file` |
| Substituir | `PUT /api/v1/assets/3d/carro.glb/` com multipart `file` |
| Excluir | `DELETE /api/v1/assets/3d/carro.glb/` |

Leitura exige autenticação; escrita e exclusão exigem superusuário. A API
bloqueia caminhos absolutos, `..`, extensões desconhecidas e uploads acima de
20 MB. Os formatos 3D aceitos são GLB, glTF e BIN.

## 7. Respostas e erros

| HTTP | Significado comum |
| --- | --- |
| `200` | Consulta ou alteração concluída |
| `201` | Registro ou asset criado |
| `204` | Exclusão concluída |
| `400` | Payload, estado ou relacionamento inválido |
| `401` | JWT ausente, expirado ou inválido |
| `403` | Conta, módulo, perfil ou tipo de usuário sem autorização |
| `404` | Recurso inexistente ou fora da conta ativa |

Erros de validação normalmente retornam um objeto JSON cujas chaves indicam
os campos inválidos. O cliente deve tratar o status HTTP e não depender apenas
do texto da mensagem.

## 8. Exemplo executável

```bash
curl -X POST http://localhost:8000/api/v1/auth/token/ \
  -H "Content-Type: application/json" \
  -d '{"identifier":"admin","password":"senha","account_id":1}'
```

Copie o valor de `access` e consulte um recurso:

```bash
curl http://localhost:8000/api/v1/veiculos/ \
  -H "Authorization: Bearer ACCESS_TOKEN"
```

Percorra `next` até que seu valor seja `null`. Quando o access expirar, renove-o
com o refresh; quando precisar mudar de conta, repita o login.
