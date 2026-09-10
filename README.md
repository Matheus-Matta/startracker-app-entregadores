# Star Tracker Entregas

Aplicativo Flutter para acompanhamento de entregas em tempo real.

A arquitetura, as politicas de cache e o resultado da revisao de desempenho
estao documentados em [PERFORMANCE.md](PERFORMANCE.md).

A auditoria de seguranca, Android, REST/WebSocket e prontidao para Google Play
esta em [AUDITORIA_PRODUCAO.md](AUDITORIA_PRODUCAO.md).

## URL do backend

A URL pode ser definida em tempo de compilação pela variável `BACKEND_URL`.
Sem essa variável, o app usa `http://10.0.2.2:8000` no emulador Android e
`http://localhost:8000` nas demais plataformas:

```powershell
flutter run
```

Também é possível sobrescrever explicitamente a URL do emulador Android:

```powershell
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:8000
```

Também é possível copiar `.env.example` para `.env`, ajustar a URL e executar:

```powershell
flutter run --dart-define-from-file=.env
```

Para gerar uma versão de produção, informe a URL HTTPS do ambiente:

```powershell
flutter build apk --release --dart-define=BACKEND_URL=https://api.exemplo.com
```

Ou usar um arquivo específico de produção:

```powershell
flutter build apk --release --dart-define-from-file=.env.production
```

O valor fica incorporado ao aplicativo durante o build. Builds release não
permitem tráfego HTTP sem criptografia; use HTTPS em produção.

## Notificações

O arquivo `.env` também configura os canais em tempo real e o canal de
notificação nativa do Android:

```dotenv
NOTIFICATIONS_ENABLED=true
FLEET_WEBSOCKET_PATH=/ws/mobile/fleet/
NOTIFICATIONS_WEBSOCKET_PATH=/ws/mobile/notifications/
NOTIFICATION_CHANNEL_ID=star_tracker_delivery_updates
NOTIFICATION_CHANNEL_NAME=Atualizacoes de entrega
NOTIFICATION_CHANNEL_DESCRIPTION=Novas waves e alteracoes de pedidos e rotas
```

Execute com `flutter run --dart-define-from-file=.env` para incorporar esses
valores. O JWT é obtido no login e enviado somente no header `Authorization`
dos handshakes WebSocket; nenhum token ou segredo deve ser gravado no `.env`.

No Android 13 ou superior, o app solicita a permissão do sistema para exibir
notificações. As opções de novas waves, alterações de rota e atualizações de
pedidos são persistidas no armazenamento seguro e podem ser alteradas na tela
de perfil.

## Login

O aplicativo autentica entregadores em
`POST /api/v1/auth/entregadores/token/`. Os tokens de acesso e renovação são
armazenados com `flutter_secure_storage`.

## Finalização da entrega

O aplicativo combina a política `delivery_config` do login (ou do endpoint de
configuração segura) com `order.proof_overrides`. Na conclusão, cria ou atualiza
o comprovante em multipart, envia cada foto separadamente e só então chama
`paradas/{id}/complete/` com o resultado de cada item. `items`, `completed_at`
e o horário da conclusão são sempre controlados pelo servidor.

## APK automático por tag

O workflow `.github/workflows/store-release.yml` valida, testa, compila e
publica o APK como artefato e GitHub Release sempre que uma tag `v*` é enviada:

```powershell
git tag v1.0.1-build5
git push origin v1.0.1-build5
```

Também são aceitas tags `v1.0.1` e `v1.0.1+5`. As configurações e credenciais
ficam no Secret `RELEASE_ENV_FILE`, conforme `STORE_RELEASE.md`. Um APK de
contingência, assinado para depuração e claramente identificado por `-debug`, é
guardado antes da validação da assinatura oficial. Ele é instalável manualmente,
mas não serve para o Google Play nem para atualizar uma instalação oficial. Com
a chave Android válida, o workflow também gera o APK e o AAB oficiais antes da
tentativa de envio ao Google Play.
