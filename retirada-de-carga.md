# Conferência de retirada da carga

Este documento explica como a Star Tracker confere a saída dos pedidos do
armazém antes da roteirização. Impressão e leitura usam a mesma configuração:
se a etiqueta é por volume, item ou pedido, a retirada exige exatamente essa
mesma quantidade de leituras.

## Objetivo

Quando `DeliveryConfig.pickup_enabled` está ativo, um pedido alocado entra em
`awaiting_pickup`. A wave não pode ser roteirizada enquanto existir um
`WaveOrder` sem `picked_up_at`.

```text
Pedido alocado
    → awaiting_pickup
    → leitura das etiquetas obrigatórias
    → ready
    → wave liberada para roteirização
```

O operador também pode remover da carga o pedido que não vai sair. Nesse caso,
ele volta para a fila sem bloquear os demais pedidos.

## Configurações

As opções ficam em **Entregas → Configurações → Retirada e etiquetas**.

| Campo | Função |
| --- | --- |
| `pickup_enabled` | Exige a conferência antes de roteirizar |
| `pickup_barcode_source` | Usa o número do pedido ou código externo |
| `label_granularity` | Define leitura por `volume`, `item` ou `order` |
| `label_code_format` | Imprime CODE128 ou QR Code |
| `label_width_mm` / `label_height_mm` | Define o tamanho físico da etiqueta |

CODE128 e QR Code mudam apenas o desenho. O valor codificado e a regra de
conferência permanecem iguais.

## Granularidade das etiquetas

### Uma etiqueta por volume

É a opção padrão. Cada pacote físico precisa ser lido. Um pedido `PED-100` com
três volumes gera:

```text
PED-100-1
PED-100-2
PED-100-3
```

O pedido só é retirado depois das três leituras. Pedido com um único volume ou
sem itemização mantém o código puro `PED-100`.

### Uma etiqueta por item

Cada produto do pedido recebe uma etiqueta, mesmo que possua vários volumes.
O código do primeiro volume representa o item.

Exemplo: um guarda-roupa com dois volumes e uma cadeira com um volume:

| Item | Volumes | Etiqueta obrigatória |
| --- | ---: | --- |
| Guarda-roupa | 2 | `PED-100-1` |
| Cadeira | 1 | `PED-100-3` |

A numeração pode pular porque continua baseada na posição física dos volumes.
No exemplo, `PED-100-2` pertence ao segundo volume do guarda-roupa, mas não é
impresso nem exigido na modalidade por item.

### Uma etiqueta por pedido

O pedido inteiro usa uma única etiqueta com o código-base:

```text
PED-100
```

Uma leitura conclui a retirada de todos os itens e volumes daquele pedido.

## Origem do código

Com `pickup_barcode_source=order_number`, a base é `order.order_number`.
Com `external_id`, a base é `order.external_id`. Se o código externo estiver
vazio, o sistema usa o número do pedido para evitar uma etiqueta inutilizável.

Espaços nas extremidades e diferença entre letras maiúsculas e minúsculas são
ignorados durante a leitura.

## Fluxo no app do entregador

1. O app consulta as waves do entregador autenticado.
2. Abre a retirada da própria wave.
3. Faz `GET` no endpoint de retirada para obter progresso e códigos pendentes.
4. Envia cada leitura por `POST` no mesmo endpoint.
5. Atualiza a interface com a resposta mais recente.
6. Quando `is_complete=true`, pode preparar e liberar a rota.

O app não deve calcular códigos nem presumir retirada por volume. A fonte de
verdade é sempre `orders[].codes` devolvido pela API.

## API de retirada

```http
GET /api/v1/delivery/waves/{wave_id}/retirada/
Authorization: Bearer ACCESS_TOKEN
```

Resposta resumida:

```json
{
  "wave_id": 42,
  "pickup_enabled": true,
  "barcode_source": "order_number",
  "label_granularity": "item",
  "total": 2,
  "picked_up": 1,
  "pending": 1,
  "is_complete": false,
  "orders": [
    {
      "order_id": 10,
      "order_number": "PED-100",
      "customer": "Cliente Exemplo",
      "codes": [
        {"code": "PED-100-1", "scanned_at": null},
        {"code": "PED-100-3", "scanned_at": null}
      ],
      "picked_up_at": null
    }
  ]
}
```

Para registrar uma leitura:

```http
POST /api/v1/delivery/waves/{wave_id}/retirada/
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{"code": "PED-100-1"}
```

O login e o endpoint de configuração do entregador publicam
`delivery_config.label_granularity`. O contrato atual possui `version=5`.

## Persistência e conclusão

Cada leitura cria um `WaveOrderPickupScan`, vinculado ao `WaveOrder`. O backend
compara o conjunto de códigos lidos com o conjunto exigido pela granularidade;
somente quando todos estão presentes ele preenche `picked_up_at` e
`picked_up_by` e move o pedido de `awaiting_pickup` para `ready`.

A retirada pertence ao vínculo com a wave, não ao pedido. Remover ou transferir
o pedido apaga o vínculo anterior; na nova carga ele precisa ser conferido de
novo. A alteração da granularidade durante cargas em andamento deve ser evitada:
finalize as cargas abertas ou reimprima suas etiquetas após a mudança.

## Erros esperados

| Situação | Resultado |
| --- | --- |
| Código vazio | “Informe o código da etiqueta” |
| Código de outra carga | “Nenhum pedido desta carga corresponde” |
| Mesma etiqueta lida novamente | “A etiqueta já havia sido lida” |
| Pedido já concluído | “O pedido já havia sido retirado” |
| Entregador de outra wave | `404` pelo escopo ou `403` sem permissão |

O entregador só pode conferir a wave atribuída a ele. Administradores precisam
da permissão da conta, e todos os querysets continuam limitados ao tenant do
JWT ou da sessão.

## Código relacionado

- `delivery/services/pickup_codes.py`: calcula os códigos obrigatórios;
- `delivery/services/pickup.py`: registra leituras e conclui pedidos;
- `delivery/services/labels.py`: gera as etiquetas impressas;
- `delivery/api_waves.py`: expõe o endpoint usado pelo app;
- `delivery/views_pickup.py`: fluxo equivalente no portal;
- `delivery/models/planning.py`: `WaveOrder` e `WaveOrderPickupScan`.
