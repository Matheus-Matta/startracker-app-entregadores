# Publicar na Play Store e App Store

Voce vai usar apenas:

- um arquivo local chamado `.env`;
- um secret no GitHub chamado `RELEASE_ENV_FILE`;
- uma tag para iniciar a publicacao.

O arquivo `.env` contem dados secretos e ja esta bloqueado pelo `.gitignore`. Nunca envie esse arquivo ao Git.

## Passo 1 — Criar o `.env`

No PowerShell, dentro da pasta do projeto:

```powershell
Copy-Item .env.example .env
```

Abra o `.env`. A URL de producao ja esta preenchida. Agora complete os campos que comecam com `COLE_AQUI_`.

## Passo 2 — Preencher os dados do Android

Voce precisa do arquivo de assinatura Android `upload-keystore.jks`.

Se ainda nao tiver esse arquivo, crie uma unica vez:

```powershell
keytool -genkeypair -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Guarde esse arquivo e as senhas em local seguro. Para converter o arquivo em Base64 e copiar o resultado:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks")) | Set-Clipboard
```

Cole o resultado no `.env` em:

```env
ANDROID_KEYSTORE_BASE64=
```

Preencha também:

```env
ANDROID_KEY_ALIAS=upload
ANDROID_KEY_PASSWORD=SENHA_DA_CHAVE
ANDROID_STORE_PASSWORD=SENHA_DO_KEYSTORE
```

Depois, baixe o JSON da service account usada pelo Google Play. Converta-o para Base64:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("service-account.json")) | Set-Clipboard
```

Cole em:

```env
PLAY_SERVICE_ACCOUNT_JSON_BASE64=
```

Deixe assim para publicar primeiro nos testes internos:

```env
PLAY_TRACK=internal
PLAY_RELEASE_STATUS=completed
```

Importante: antes da primeira publicacao automatica, crie o aplicativo `com.startracker.star_tracker` no Play Console e envie um AAB manualmente uma vez.

## Passo 3 — Preencher os dados do iPhone

No Apple Developer/App Store Connect, o aplicativo deve usar este Bundle ID:

```env
IOS_BUNDLE_ID=br.dev.star.tracker.entregas
```

Preencha no `.env`:

```env
IOS_TEAM_ID=SEU_TEAM_ID
APPSTORE_ISSUER_ID=SEU_ISSUER_ID
APPSTORE_API_KEY_ID=SEU_KEY_ID
```

Converta a chave `AuthKey_XXXX.p8` para Base64:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXX.p8")) | Set-Clipboard
```

Cole em:

```env
APPSTORE_API_PRIVATE_KEY_BASE64=
```

Exporte o certificado Apple Distribution como `.p12`. Depois converta:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("certificado.p12")) | Set-Clipboard
```

Cole e informe a senha:

```env
APPSTORE_CERTIFICATES_FILE_BASE64=
APPSTORE_CERTIFICATES_PASSWORD=SENHA_DO_P12
```

O provisioning profile deve ser do tipo App Store e ter este nome:

```env
IOS_PROVISIONING_PROFILE_NAME=AppStore br.dev.star.tracker.entrega
```

## Passo 4 — Cadastrar o unico secret no GitHub

1. Abra o repositorio no GitHub.
2. Clique em **Settings**.
3. Clique em **Secrets and variables**.
4. Clique em **Actions**.
5. Clique em **New repository secret**.
6. No nome, informe exatamente:

```text
RELEASE_ENV_FILE
```

7. No valor, copie e cole o conteudo completo do seu arquivo `.env`.
8. Clique em **Add secret**.

Nao e necessario criar outros secrets ou environments.

## Passo 5 — Publicar

Primeiro envie as alteracoes do projeto para o GitHub. Depois crie uma tag simples com a nova versao:

```powershell
git tag -a "v1.0.39" -m "Release 1.0.39"
git push origin "v1.0.39"
```

O workflow gera automaticamente um numero interno crescente para o Android e o iOS.

O GitHub Actions vai automaticamente:

1. testar o aplicativo;
2. gerar APK e AAB assinados;
3. enviar o AAB ao teste interno do Google Play;
4. gerar o IPA assinado;
5. enviar o IPA ao TestFlight;
6. criar a release da tag no GitHub.

Para acompanhar, abra a aba **Actions** do repositorio no GitHub.

## Publicar para todos no Google Play

Depois de testar a versao interna, altere no `.env`:

```env
PLAY_TRACK=production
```

Atualize o secret `RELEASE_ENV_FILE` no GitHub com o novo conteúdo e crie uma nova tag.

No iPhone, o workflow envia para o TestFlight. A liberacao publica ainda precisa ser enviada para revisao pelo App Store Connect.
