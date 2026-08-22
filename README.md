# Star Tracker Entregas

Aplicativo Flutter para acompanhamento de entregas em tempo real.

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
