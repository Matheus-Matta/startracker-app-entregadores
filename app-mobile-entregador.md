# Configuração do app mobile do entregador

Este guia descreve o contrato que o app mobile deve usar para permitir que o
entregador altere sua disponibilidade e confirme uma entrega com a localização
do celular. O cruzamento com o destino planejado e com o rastreador do veículo é
feito pelo backend.

## Preparação no portal

Antes de liberar o recurso no app:

1. habilite o módulo **Entregas** para a conta;
2. associe o usuário ao perfil **Entregador** (`delivery_driver`) nessa conta;
3. mantenha um `DriverProfile` ativo e vinculado ao mesmo usuário e conta;
4. em **Entregas → Config. entrega → Comprovante**, configure:
   - raio permitido em relação ao endereço planejado;
   - raio de comparação entre celular e rastreador;
   - janela de tempo para localizar uma posição do rastreador;
5. para comparar com o rastreador, associe um dispositivo ao veículo e mantenha
   a ingestão de posições ativa.

O rastreador é opcional. Sua ausência não impede a entrega e é registrada no
resultado da auditoria.

## Login e atualização da configuração

Use o login exclusivo do entregador:

```http
POST /api/v1/auth/entregadores/token/
Content-Type: application/json

{
  "identifier": "entregador@example.com",
  "password": "senha-segura",
  "account_id": 1
}
```

Guarde `access` e `refresh` no armazenamento seguro do sistema operacional. As
rotas operacionais usam a conta contida no JWT; o app não deve tentar trocar o
tenant enviando outro `account_id`.

O login devolve `delivery_config`. Atualize esse objeto ao abrir o perfil, ao
retomar o app e depois de renovar uma sessão:

```http
GET /api/v1/auth/entregadores/configuracao/
Authorization: Bearer ACCESS_TOKEN
```

Na versão `6`, os trechos relevantes são:

```json
{
  "delivery_config": {
    "version": 6,
    "availability": {
      "can_edit": true,
      "driver_id": 7,
      "value": "available",
      "label": "Disponível",
      "options": [
        {"value": "available", "label": "Disponível"},
        {"value": "busy", "label": "Ocupado"},
        {"value": "offline", "label": "Desconectado"}
      ],
      "update_url": "/api/v1/delivery/entregadores/7/disponibilidade/",
      "method": "POST"
    },
    "confirmation_location": {
      "enabled": true,
      "required": false,
      "request_fresh_location": true,
      "complete_url_template": "/api/v1/delivery/paradas/{stop_id}/complete/",
      "method": "POST",
      "latitude_field": "delivery_actual_lat",
      "longitude_field": "delivery_actual_lng",
      "compare_with_planned_destination": true,
      "planned_destination_radius_m": 200,
      "compare_with_tracker_when_available": true,
      "tracker_radius_m": 200,
      "tracker_time_tolerance_minutes": 10
    }
  }
}
```

Não fixe opções, IDs, URLs ou raios no código mobile. Eles podem mudar por conta
e devem sempre vir do servidor.

## Disponibilidade no perfil

Mostre o seletor somente quando `availability.can_edit` for `true`. Monte as
opções com `availability.options` e salve usando `update_url` e `method`:

```http
POST /api/v1/delivery/entregadores/7/disponibilidade/
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{"availability": "offline"}
```

Use o objeto retornado pela API para atualizar a tela. `offline` impede novas
alocações automáticas. O início de uma rota muda o estado para `busy` e seu
encerramento volta para `available`; quem marcou `offline` manualmente não é
reativado pelo encerramento da rota.

## Localização na confirmação da entrega

Ao tocar em **Confirmar entrega**, o app deve solicitar uma posição nova ao GPS,
com alta precisão, cache desativado e timeout razoável. Solicite as permissões de
localização exigidas pelo Android ou iOS e não reutilize silenciosamente uma
posição antiga.

Depois de salvar o comprovante, assinatura, fotos e resultados por item, troque
`{stop_id}` na URL publicada e envie o par de coordenadas:

```http
POST /api/v1/delivery/paradas/42/complete/
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{
  "delivery_actual_lat": -22.8301,
  "delivery_actual_lng": -43.0402
}
```

Latitude e longitude devem ser enviadas juntas. Um par incompleto ou inválido
responde `400`. A política atual mantém a localização opcional: se a permissão
for negada ou o GPS falhar, avise claramente o entregador e permita continuar
sem os dois campos. O servidor registra seu próprio horário de confirmação.

Quando houver resultado por item, inclua `item_results` no mesmo JSON da
conclusão. Assinatura e fotos continuam sendo enviadas antes, nos endpoints de
comprovantes e fotos; não pertencem a esta chamada.

## Resultado da auditoria

Na resposta, `proof` contém o snapshot calculado pelo servidor:

- `delivery_actual_lat`, `delivery_actual_lng` e `delivery_actual_address`;
- `delivery_distance_from_planned_m` e `delivery_within_planned_radius`;
- `tracker_lat`, `tracker_lng`, `tracker_position_at` e `tracker_distance_m`;
- `tracker_validation_status` e `tracker_validation_label`.

Os estados do rastreador são:

| Código | Rótulo | Significado |
| --- | --- | --- |
| `MATCH` | Compatível | Celular e rastreador estão dentro do raio configurado |
| `DIVERGENT` | Divergente | A distância ultrapassa o raio configurado |
| `NO_TRACKER` | Sem rastreador | O veículo não possui histórico de rastreador |
| `NO_DATA` | Sem posição recente do rastreador | Não há posição dentro da janela configurada |
| `NO_LOCATION` | Localização do celular indisponível | A confirmação não recebeu coordenadas |

O app não deve consultar posições do rastreador nem calcular distâncias. O
backend escolhe a posição temporalmente mais próxima da confirmação, aplica o
escopo da conta e devolve o resultado pronto.

## Falhas, modo offline e repetição

- envie primeiro todos os dados exigidos pelo comprovante e só então conclua;
- mantenha a confirmação em uma fila local enquanto estiver sem conexão;
- ao repetir uma requisição, consulte antes a parada: uma baixa já concluída não
  tem seu snapshot de auditoria sobrescrito;
- em `400`, preserve os dados locais, mostre as validações recebidas e permita a
  correção;
- em `401`, renove o token antes de repetir; em `403` ou `404`, sincronize a
  sessão, a conta e as rotas do entregador.

## Checklist do app

- perfil exibe a disponibilidade somente quando autorizada pelo contrato;
- opções e endpoint de atualização vêm de `delivery_config`;
- confirmação pede uma posição nova e envia latitude e longitude juntas;
- falha de GPS não é confundida com entrega divergente;
- resultado apresentado usa `tracker_validation_label` devolvido pelo backend;
- configuração é sincronizada ao entrar no app, retomar e abrir o perfil.
