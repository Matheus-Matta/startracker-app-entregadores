# Auditoria de producao — Star Tracker Entregas

Data da auditoria: 25/08/2026  
Escopo: codigo Flutter/Dart, configuracao Android, dependencias, contrato REST em
`api-rest.md`, APK de debug e artefatos locais de build.

## A. Resumo executivo

**Classificacao: NAO PRONTO PARA PRODUCAO.**

O aplicativo possui uma base funcional boa: JWT em armazenamento protegido,
refresh single-flight, REST com timeouts, WebSocket autenticado por header,
heartbeat, reconexao, cache com invalidacao, API 36 e separacao de cleartext
entre debug e release. Esta auditoria tambem corrigiu condicoes de corrida de
sessao, lifecycle de GPS/WebSocket, backup, permissoes, assinatura release,
jitter e limites de payload.

Ainda existem cinco bloqueios de alta prioridade:

1. a upload key e a configuracao real de assinatura nao foram fornecidas;
2. nao existe configuracao real de producao com host HTTPS;
3. a conclusao de entrega e uma sequencia multipartes sem recuperacao duravel;
4. notificacoes dependem do processo aberto, pois nao ha FCM;
5. politica de privacidade e declaracoes da Play Console nao estao nos arquivos.

### Contagem de achados abertos

| Severidade | Quantidade |
| --- | ---: |
| P0 — Critico | 0 |
| P1 — Alto | 5 |
| P2 — Medio | 8 |
| P3 — Baixo | 1 |

Achados corrigidos durante a auditoria: 1 P1, 4 P2 e 1 P3. Eles aparecem na
secao de patches e nao entram na contagem de pendencias.

## B. Inventario tecnico

| Item | Evidencia/valor |
| --- | --- |
| Flutter | 3.44.4 stable, revisao `ad70ec4617` |
| Dart | 3.12.2 |
| DevTools | 2.57.0 |
| compileSdk / targetSdk / minSdk | 36 / 36 / 24 |
| NDK | 28.2.13676358 |
| Android Gradle Plugin | 8.11.1 |
| Gradle | 8.14 |
| Kotlin | 2.3.20; plugins legados ainda aplicam KGP |
| Java | 17 |
| Estado | `StatefulWidget`, `setState`, `FutureBuilder`; sem Bloc/Riverpod |
| REST | Dio 5.11.0 |
| WebSocket | web_socket_channel 3.0.3 / IOWebSocketChannel |
| Secure storage | flutter_secure_storage 10.0.0 |
| Banco local | nenhum |
| Notificacoes | flutter_local_notifications 22.3.0; sem push/FCM |
| Firebase/Crashlytics/Sentry | ausentes |
| WorkManager | removido nesta auditoria; implementacao existente era stub e nao usada |
| Flavors | nenhum |
| Ambientes | arquivos dart-define; exemplo dev e exemplo production |
| CI/CD | ausente |
| Logs/telemetria | nenhum sistema estruturado encontrado |
| API | `/api/v1`; eventos WebSocket sem campo de versao/cursor documentado |

Bibliotecas nativas encontradas no APK: Flutter engine, MapLibre,
Barcode/ML Kit (`libbarhopper_v3.so`), JNI do Dart e utilitarios de imagem. No
ARM64, todos os segmentos `LOAD` inspecionados estavam alinhados em `0x4000` ou
`0x10000`. O APK tambem passou em `zipalign -c -P 16 -v 4`. O teste funcional
em dispositivo/emulador com pagina de 16 KB ainda precisa ser executado.

### Arquitetura observada

```text
Widget / StatefulWidget
    |
    +-- setState / FutureBuilder
    |
    +-- Service compartilhado via AppDependencies
            |
            +-- ApiClient / Dio --------> REST /api/v1
            |
            +-- AuthenticatedWebSocket -> WS fleet / notifications
            |
            +-- SessionStorage ---------> Android Keystore + arquivo cifrado
```

Nao ha repository ou fonte local persistente. REST e a fonte da verdade; o
WebSocket funciona como sinal de invalidacao que provoca nova leitura REST.
Essa escolha evita confiar cegamente em eventos, mas deixa UI, sincronizacao e
orquestracao ainda muito proximas.

## C. Achados detalhados

### F-01 — Assinatura de release ainda nao configurada

1. **Severidade:** P1 — Alto; bloqueia publicacao.
2. **Categoria:** Android / signing / supply chain.
3. **Arquivo:** `android/app/build.gradle.kts`, `android/key.properties.example`.
4. **Classe/funcao:** `signingConfigs.release` e validacao `releaseRequested`.
5. **Evidencia:** o projeto anterior usava `signingConfigs.getByName("debug")`;
   o patch agora exige `android/key.properties`, que ainda nao existe.
6. **Problema:** nao ha upload key real nem credenciais injetadas por CI.
7. **Por que e problema:** APK/AAB de debug nao e uma identidade publicavel e
   compromete rastreabilidade e atualizacoes futuras.
8. **Cenario real:** tentativa de publicar falha, ou uma chave compartilhada em
   maquina local e perdida/vazada.
9. **Correcao recomendada:** gerar upload key, ativar Play App Signing, guardar
   senhas no cofre do CI e fazer backup seguro da chave.
10. **Codigo corrigido:** o Gradle le `key.properties`, usa somente o signing
    `release` e falha cedo se a chave estiver ausente.
11. **Impacto:** impede release inseguro; requer provisionamento externo.
12. **Como testar:** executar `flutter build appbundle --release
    --dart-define-from-file=.env.production` e conferir assinatura com
    `apksigner verify --verbose --print-certs`.
13. **Referencia:** documentacao Android sobre
    [assinatura de apps](https://developer.android.com/studio/publish/app-signing).

### F-02 — Ambiente real de producao e flavors ausentes

1. **Severidade:** P1 — Alto.
2. **Categoria:** configuracao / rede / DevOps.
3. **Arquivo:** `.env`, `.env.production.example`, `lib/core/config/app_config.dart`.
4. **Classe/funcao:** `AppConfig.backendUrl` e `validateBackendUrl`.
5. **Evidencia:** o `.env` local aponta para `http://localhost:8000`; nao existe
   `.env.production` real nem flavors `dev/staging/prod`.
6. **Problema:** nao ha host HTTPS de producao verificavel nem separacao forte
   de artefatos/IDs por ambiente.
7. **Por que e problema:** um artefato pode apontar para ambiente incorreto; em
   aparelho, `localhost` e o proprio telefone.
8. **Cenario real:** release chega ao Play e falha no login, ou usa dados de
   staging por engano.
9. **Correcao recomendada:** provisionar URL HTTPS, criar flavors quando houver
   staging, e controlar os arquivos de define no CI.
10. **Codigo corrigido:** release agora rejeita HTTP em Dart e no Gradle; o
    Manifest principal proibe cleartext e o overlay debug o libera explicitamente.
11. **Impacto:** falha segura em vez de publicar configuracao insegura.
12. **Como testar:** build release com HTTP deve falhar; build com HTTPS e upload
    key deve passar; inspecionar Manifest release.
13. **Referencia:** [Network Security Configuration](https://developer.android.com/privacy-and-security/security-config).

### F-03 — Conclusao de entrega nao e recuperavel como uma operacao unica

1. **Severidade:** P1 — Alto.
2. **Categoria:** integridade / idempotencia / offline.
3. **Arquivo:** `lib/features/waves/data/active_route_service.dart`.
4. **Classe/funcao:** `ActiveRouteService.complete`.
5. **Evidencia:** executa criar/editar comprovante, um POST por foto e, por fim,
   `paradas/{id}/complete/`; nao ha idempotency key nem estado local duravel.
6. **Problema:** falha no meio deixa estado parcial. O contrato informa um unico
   comprovante por parada e sequencia unica por foto, mas o widget continua com
   o snapshot antigo depois de uma falha.
7. **Por que e problema:** retry pode tentar criar novamente o comprovante ou
   reenviar uma sequencia existente, impedindo a conclusao.
8. **Cenario real:** sinal cai apos a segunda foto; o motorista tenta novamente,
   recebe 400 e fica bloqueado apesar de parte da prova estar no servidor.
9. **Correcao recomendada:** preferencialmente criar endpoint backend atomico ou
   sessao de upload com `operation_id`/`Idempotency-Key`; como fallback, persistir
   progresso por usuario/parada e reconciliar comprovante/fotos antes do retry.
10. **Codigo recomendado:**

```text
POST /paradas/{id}/completion-sessions
Idempotency-Key: UUID
-> session_id, proof_id, uploaded_sequences

PUT /completion-sessions/{session_id}/photos/{sequence}
POST /completion-sessions/{session_id}/commit
```

11. **Impacto:** exige contrato backend e migracao coordenada; elimina duplicacao
    e permite continuar apos process death.
12. **Como testar:** cortar rede depois de cada etapa, matar processo e repetir a
    mesma chave; o resultado final deve conter um comprovante e cada foto uma vez.
13. **Referencia:** OWASP MASVS-AUTH/NETWORK e principio de idempotencia de APIs.

### F-04 — Notificacoes nao funcionam com processo encerrado

1. **Severidade:** P1 — Alto, considerando notificacao como requisito do produto.
2. **Categoria:** background / confiabilidade.
3. **Arquivo:** `lib/core/notifications/app_notification_manager.dart` e
   `pubspec.yaml`.
4. **Classe/funcao:** `AppNotificationManager.start`.
5. **Evidencia:** notificacao nativa nasce de WebSocket Dart; nao existem
   `firebase_core`, `firebase_messaging` ou registro de device token.
6. **Problema:** Android pode suspender/matar o processo; sem processo nao ha
   socket nem notificacao local.
7. **Por que e problema:** wave nova ou alteracao urgente pode nunca alertar o
   entregador em background/terminated.
8. **Cenario real:** aparelho bloqueado, processo removido, wave atribuida; nada
   aparece ate o usuario abrir o aplicativo.
9. **Correcao recomendada:** foreground = REST+WS; background/terminated = FCM;
   resumed = reconnect + reconciliacao REST. Registrar/remover token por sessao.
10. **Codigo recomendado:** handler top-level FCM, payload minimo sem PII e
    endpoint backend de dispositivos com rotacao/revogacao.
11. **Impacto:** nova dependencia, configuracao Firebase e trabalho backend.
12. **Como testar:** foreground, background, terminated, force-stop, token
    rotacionado, logout e dois aparelhos.
13. **Referencia:** [recebimento FCM no Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages).

### F-05 — Evidencias de privacidade e Play Data Safety ausentes

1. **Severidade:** P1 — Alto para publicacao.
2. **Categoria:** privacidade / Google Play.
3. **Arquivo:** Manifest e telas de entrega; nenhuma politica encontrada.
4. **Classe/funcao:** captura de GPS, camera, assinatura, nome e documento.
5. **Evidencia:** `ACCESS_FINE_LOCATION`, `CAMERA`, fotos, coordenadas, telefone,
   endereco e documento sao processados; nao existe link/tela de politica.
6. **Problema:** finalidade, retencao, compartilhamento e exclusao nao estao
   declarados nos arquivos.
7. **Por que e problema:** dados pessoais/sensiveis exigem transparencia e uma
   declaracao coerente na Play Console.
8. **Cenario real:** rejeicao de publicacao ou declaracao Data Safety divergente
   do comportamento real.
9. **Correcao recomendada:** inventario com controlador, finalidade, retencao,
   base legal, subprocessadores e canal do titular; publicar politica e preencher
   Data Safety com dados do app e SDKs.
10. **Codigo corrigido:** permissao de localizacao em background foi removida por
    nao haver fluxo ativo; ainda e necessario o documento juridico/operacional.
11. **Impacto:** nao altera logica; exige decisao do controlador e backend.
12. **Como testar:** comparar Manifest, trafego e SDK Index com cada resposta do
    formulario Play.
13. **Referencia:** [declaracao de uso de dados](https://developer.android.com/privacy-and-security/declare-data-use).

`❓ NÃO VERIFICÁVEL COM OS ARQUIVOS DISPONÍVEIS`: politica hospedada, formulario
Data Safety, prazos reais de retencao e contratos com operadores nao foram
fornecidos.

### F-06 — Eventos WebSocket nao possuem cursor, versao ou deduplicacao

1. **Severidade:** P2 — Medio.
2. **Categoria:** WebSocket / consistencia distribuida.
3. **Arquivo:** `api-rest.md`, `fleet_realtime_channel.dart` e
   `notification_realtime_channel.dart`.
4. **Classe/funcao:** parsers `tryParse`.
5. **Evidencia:** contrato usa apenas `type` e `data`; nao documenta `eventId`,
   `sequence`, `version` ou `updatedSince`.
6. **Problema:** nao e possivel provar quais eventos foram perdidos, duplicados
   ou recebidos fora de ordem.
7. **Por que e problema:** reconexao pode deixar estado temporariamente obsoleto.
8. **Cenario real:** rota muda duas vezes durante troca Wi-Fi/4G e o cliente
   recebe somente a segunda notificacao ou uma mensagem antiga atrasada.
9. **Correcao recomendada:** versionar envelope e expor cursor/sync REST.
10. **Codigo corrigido:** ao reconectar, fleet recebe `connected` e relê REST;
    notificacoes agora tambem relêem REST. E uma reconciliacao de snapshot, nao
    substitui cursor do servidor.
11. **Impacto:** baixo no cliente; medio no backend/contrato.
12. **Como testar:** duplicar, reordenar e omitir eventos; snapshot final deve
    coincidir com REST.
13. **Referencia:** RFC 6455 define transporte, nao semantica de consistencia.

### F-07 — Sem estrategia offline ou outbox persistente

1. **Severidade:** P2 — Medio; sobe para P1 nas operacoes de prova.
2. **Categoria:** offline / process death.
3. **Arquivo:** projeto inteiro; nenhum banco local encontrado.
4. **Classe/funcao:** formularios de retirada, parada e conclusao.
5. **Evidencia:** estado e fotos ficam somente em memoria; falha de rede retorna
   mensagem e nao cria fila.
6. **Problema:** comportamento offline nao esta definido por operacao.
7. **Por que e problema:** entregas ocorrem em locais com conectividade ruim e o
   Android pode matar o processo.
8. **Cenario real:** usuario captura cinco fotos, troca de app e o processo morre;
   todo o trabalho e perdido.
9. **Correcao recomendada:** definir quais acoes falham imediatamente e quais vao
   para outbox cifrada e isolada por usuario, com UUID, TTL, tentativas e chave
   idempotente.
10. **Codigo recomendado:** repository com `LocalDataSource + OutboxWorker` e
    limpeza obrigatoria no logout.
11. **Impacto:** mudanca arquitetural relevante; deve vir junto de F-03.
12. **Como testar:** modo aviao, process death, troca de conta e retomada.
13. **Referencia:** WorkManager e apropriado para trabalho persistente depois que
    existir uma fila real: [tarefas persistentes](https://developer.android.com/develop/background-work/background-tasks/persistent).

### F-08 — Sem observabilidade e tratamento global de falhas

1. **Severidade:** P2 — Medio.
2. **Categoria:** operacao / confiabilidade.
3. **Arquivo:** `lib/main.dart` e projeto inteiro.
4. **Classe/funcao:** `main`.
5. **Evidencia:** apenas `runApp`; sem `FlutterError.onError`,
   `PlatformDispatcher.onError`, Crashlytics, Sentry ou metricas.
6. **Problema:** crashes, refresh falho, timeout e reconexoes nao geram sinal
   operacional estruturado.
7. **Por que e problema:** regressao em milhares de aparelhos fica invisivel.
8. **Cenario real:** plugin nativo falha em um fabricante especifico e suporte
   recebe relatos sem stack trace/simbolos.
9. **Correcao recomendada:** integrar coletor aprovado, ambientes/releases,
   redaction de Authorization, documento, telefone e endereco.
10. **Codigo recomendado:** handlers globais que encaminham erro sanitizado sem
    substituir os handlers do Flutter.
11. **Impacto:** dependencia e governanca de privacidade.
12. **Como testar:** erro Flutter, Future nao aguardada e erro nativo em release.
13. **Referencia:** [tratamento de erros Flutter](https://docs.flutter.dev/testing/errors).

### F-09 — Cobertura insuficiente de integracao, lifecycle e rede hostil

1. **Severidade:** P2 — Medio.
2. **Categoria:** testes.
3. **Arquivo:** `test/`; nao existe `integration_test/`.
4. **Classe/funcao:** suite atual.
5. **Evidencia:** ha testes unitarios/widget, mas nao login real, 50x401,
   reconexao, process death, upload interrompido ou 10 mil eventos.
6. **Problema:** caminhos de maior risco nao sao executados de ponta a ponta.
7. **Por que e problema:** analyzer e unit tests nao detectam Doze, plugin nativo,
   Manifest, rede lenta ou morte do processo.
8. **Cenario real:** refresh funciona no fake, mas falha com proxy/latencia real.
9. **Correcao recomendada:** servidor fake controlavel, integration tests Android,
   matrix API 24/29/33/36 e perfil de rede.
10. **Codigo corrigido:** adicionados testes de single-flight, rotacao e logout
    durante refresh; permanecem os cenarios de dispositivo.
11. **Impacto:** custo de infraestrutura de teste; reduz regressao.
12. **Como testar:** usar a matriz da secao E.
13. **Referencia:** documentacao Flutter de
    [integration testing](https://docs.flutter.dev/testing/integration-tests).

### F-10 — UI ainda concentra estado e orquestracao de dominio

1. **Severidade:** P2 — Medio.
2. **Categoria:** arquitetura / manutencao.
3. **Arquivo:** `active_wave_page.dart`, `delivery_completion_page.dart` e tabs.
4. **Classe/funcao:** States das paginas.
5. **Evidencia:** widgets chamam services, controlam corrida, retry, cache visual,
   navegacao e mensagens.
6. **Problema:** falta uma camada de estado/repository por feature.
7. **Por que e problema:** regras ficam dificeis de testar e sobrevivem apenas ao
   ciclo de vida do widget.
8. **Cenario real:** alteracao no fluxo de entrega exige editar pagina de mais de
   mil linhas e cria regressao de estado.
9. **Correcao recomendada:** migracao incremental por feature para controller/
   Cubit/Notifier, repository e modelos de estado imutaveis.
10. **Codigo corrigido:** `AppDependencies`, servicos e WebSocket manager ja sao
    uma base de composicao; dependencias Bloc e MVP sem uso foram removidas.
11. **Impacto:** medio; nao reescrever todas as telas de uma vez.
12. **Como testar:** unit tests do controller sem WidgetTester e golden/widget
    tests apenas para renderizacao.
13. **Referencia:** principios de separacao de responsabilidades; nao ha uma
    biblioteca obrigatoria.

### F-11 — Fotos ficam integralmente na memoria e nao ha limite local de bytes

1. **Severidade:** P2 — Medio.
2. **Categoria:** memoria / uploads.
3. **Arquivo:** `delivery_completion_page.dart` e `active_route_service.dart`.
4. **Classe/funcao:** `_takePhoto`, `_CapturedPhoto`, `complete`.
5. **Evidencia:** `readAsBytes`, lista de `Uint8List` e MultipartFile.fromBytes;
   imagem e reduzida para largura 1800/qualidade 78, mas nao se valida 10 MB.
6. **Problema:** varias imagens e copias multipart podem elevar o heap; MIME e
   tamanho dependem do backend.
7. **Por que e problema:** aparelho de pouca RAM pode sofrer jank/OOM; erro de 10
   MB ocorre apenas depois do upload.
8. **Cenario real:** cinco fotos complexas e assinatura coexistem em memoria ao
   abrir mapa e scanner.
9. **Correcao recomendada:** validar bytes, dimensoes e extensao antes de guardar;
   manter arquivos temporarios privados e fazer upload streaming/um por vez.
10. **Codigo recomendado:** rejeitar `bytes.length > 10 * 1024 * 1024`, gerar
    nome/MIME conhecido e apagar temporarios no sucesso/logout.
11. **Impacto:** melhora memoria; exige cuidado com process death e criptografia.
12. **Como testar:** fotos 9,9/10/10,1 MB e heap em aparelho de 2–3 GB.
13. **Referencia:** limite de 10 MB esta documentado em `api-rest.md`.

### F-12 — Supply chain sem scanner, CI ou SBOM; plugins Kotlin legados

1. **Severidade:** P2 — Medio.
2. **Categoria:** supply chain / DevOps.
3. **Arquivo:** `pubspec.lock`, Gradle; pipeline ausente.
4. **Classe/funcao:** build.
5. **Evidencia:** `flutter pub outdated` mostra majors pendentes; build avisa que
   MapLibre e Mobile Scanner ainda aplicam KGP legado; OSV Scanner nao instalado.
6. **Problema:** nao existe gate automatizado de vulnerabilidade, licenca,
   analyzer, teste, AAB e assinatura.
7. **Por que e problema:** dependencia vulneravel ou build nao reproduzivel pode
   chegar a producao sem revisao.
8. **Cenario real:** proxima versao do Flutter remove compatibilidade KGP e CI
   deixa de compilar no dia da release.
9. **Correcao recomendada:** pipeline com lockfile, `flutter analyze/test`, OSV ou
   equivalente, SBOM CycloneDX, build AAB e artefatos/simbolos por commit.
10. **Codigo corrigido:** removidos `workmanager` e `flutter_bloc` que nao eram
    usados; nao foram feitos upgrades major cegos.
11. **Impacto:** reduz dependencias e antecipa regressao.
12. **Como testar:** pipeline limpo em runner novo e politica de atualizacao
    mensal com changelog/testes.
13. **Referencia:** [Google Play SDK Index](https://developer.android.com/distribute/sdk-index).

### F-13 — Cancelamento, rate limit e status HTTP ainda sao genericos

1. **Severidade:** P3 — Baixo.
2. **Categoria:** REST / UX / resiliencia.
3. **Arquivo:** services e paginas de lista.
4. **Classe/funcao:** chamadas Dio e `_errorMessage`.
5. **Evidencia:** nao ha `CancelToken`; 408/409/410/422/429/503 normalmente viram
   mensagem generica; nao ha `Retry-After`.
6. **Problema:** chamadas antigas continuam e o usuario nao recebe acao adequada.
7. **Por que e problema:** busca longa pode terminar depois da tela; 429 pode
   provocar repeticao manual agressiva.
8. **Cenario real:** servidor pede espera de 60 s, mas UI oferece retry imediato.
9. **Correcao recomendada:** mapper central de falhas; cancelar GET substituido;
   respeitar Retry-After somente em operacoes idempotentes.
10. **Codigo recomendado:** `ApiFailure` tipado e `CancelToken` por controller.
11. **Impacto:** melhoria incremental sem mudar backend.
12. **Como testar:** matriz 400/401/403/404/409/422/429/5xx e dispose durante GET.
13. **Referencia:** sem retry automatico em mutacoes sem idempotencia.

### F-14 — Backup e permissoes excessivas — corrigido

1. **Severidade original:** P2 — Medio.
2. **Categoria:** Android / armazenamento / privacidade.
3. **Arquivo:** `android/app/src/main/AndroidManifest.xml`.
4. **Classe/funcao:** `<application>` e `<uses-permission>`.
5. **Evidencia:** faltavam regras de backup e havia background location/FGS sem
   uso; WorkManager era stub nao referenciado.
6. **Problema:** risco de restaurar armazenamento cifrado sem chave compativel e
   de exigir declaracao Play desnecessaria.
7. **Por que e problema:** restore pode quebrar secure storage; permissao sensivel
   aumenta revisao e expectativa do usuario.
8. **Cenario real:** app restaurado em outro aparelho tem ciphertext sem chave;
   Play pede video/politica de background location sem feature demonstravel.
9. **Correcao:** backups e device transfer excluidos; permissoes e dependencia
   morta removidas.
10. **Codigo corrigido:** `allowBackup=false`, `fullBackupContent=false`,
    `dataExtractionRules`, sem `ACCESS_BACKGROUND_LOCATION`.
11. **Impacto:** usuario precisa autenticar depois de reinstalacao/migracao.
12. **Como testar:** merged manifest, backup/restore e nova autenticacao.
13. **Referencia:** flutter_secure_storage 10 usa RSA-OAEP + AES-GCM e recomenda
    tratar backup: [package oficial](https://pub.dev/packages/flutter_secure_storage).

### F-15 — Refresh podia restaurar sessao depois do logout — corrigido

1. **Severidade original:** P1 — Alto.
2. **Categoria:** autenticacao / race condition.
3. **Arquivo:** `api_client.dart`, `session_storage.dart`, `auth_service.dart`.
4. **Classe/funcao:** `_requestNewAccessToken`, `_refreshSession`.
5. **Evidencia:** refresh em voo gravava o novo token sem verificar se logout ou
   login de outra conta ocorreu; restore tinha um fluxo de refresh separado.
6. **Problema:** resposta antiga podia ressuscitar sessao encerrada.
7. **Por que e problema:** viola logout e pode misturar identidade/cache.
8. **Cenario real:** request recebe 401, usuario sai, refresh responde e regrava
   access/refresh.
9. **Correcao:** geracao de sessao, single-flight por cliente, descarte de resposta
   obsoleta, rotacao do refresh e limpeza em 400/401/403.
10. **Codigo corrigido:** implementado nos tres arquivos e coberto por testes.
11. **Impacto:** logout passa a ser monotonicamente seguro.
12. **Como testar:** dois refresh simultaneos e logout antes da resposta.
13. **Referencia:** MASVS-AUTH.

### F-16 — Lifecycle e reconexao WebSocket/GPS incompletos — corrigido

1. **Severidade original:** P2 — Medio.
2. **Categoria:** realtime / bateria / lifecycle.
3. **Arquivo:** `authenticated_websocket.dart`, `delivery_page.dart`,
   `active_wave_page.dart`.
4. **Classe/funcao:** reconnect e `didChangeAppLifecycleState`.
5. **Evidencia:** backoff era deterministico e sockets/GPS continuavam enquanto
   widgets permanecessem montados em background.
6. **Problema:** thundering herd, rede e GPS desnecessarios em background.
7. **Por que e problema:** bateria e carga de servidor em quedas coletivas.
8. **Cenario real:** milhares de aparelhos reconectam nos mesmos segundos.
9. **Correcao:** equal jitter, teto de 32 s, ping 25 s, connect timeout 15 s,
   stop em paused/hidden e resync no resume.
10. **Codigo corrigido:** implementado; payload acima de 256 KiB e parser invalido
    tambem sao descartados.
11. **Impacto:** menor bateria/carga; background passa a depender de push.
12. **Como testar:** alternar foreground/background e derrubar servidor/rede.
13. **Referencia:** RFC 6455 e orientacao Android sobre
    [uso de rede em background](https://developer.android.com/topic/performance/vitals/bg-network-usage).

### F-17 — Dados excessivos em notificacao local — corrigido

1. **Severidade original:** P3 — Baixo.
2. **Categoria:** privacidade / notificacoes.
3. **Arquivo:** `app_notification_manager.dart`, `notification_service.dart`.
4. **Classe/funcao:** `_onPersonalNotification`, `_show`, `tryParse`.
5. **Evidencia:** todo `notification.data` era copiado para o payload do SO.
6. **Problema:** campos futuros/PII poderiam ficar em extras e lock screen.
7. **Por que e problema:** minimizacao de dados e defesa contra payload remoto.
8. **Cenario real:** backend acrescenta endereco/documento e app o persiste sem
   mudanca de codigo.
9. **Correcao:** allowlist de IDs, visibilidade privada e limites de string.
10. **Codigo corrigido:** implementado.
11. **Impacto:** nenhum fluxo atual consome os campos removidos.
12. **Como testar:** enviar campo inesperado e inspecionar payload local.
13. **Referencia:** MASVS-PRIVACY.

## D. Top 10 riscos e plano de correcao

| Ordem | Risco | Acao |
| ---: | --- | --- |
| 1 | Conclusao parcial/irrecuperavel | endpoint idempotente + sessao/outbox |
| 2 | Release sem upload key | provisionar Play App Signing e CI secrets |
| 3 | Release sem host HTTPS real | configurar producao/flavor e smoke test |
| 4 | Notificacao perdida com processo morto | integrar FCM e device registry |
| 5 | Rejeicao/risco de privacidade | politica, Data Safety e inventario |
| 6 | Eventos perdidos/fora de ordem | envelope versionado + cursor/sync |
| 7 | Sem teste de process death/rede real | integration + chaos matrix |
| 8 | Sem observabilidade | crash/metricas com redaction |
| 9 | Fotos pressionam heap | limite local + streaming/temporarios |
| 10 | Supply chain sem gate | CI, scanner, SBOM e politica de upgrade |

### Antes de producao

- Resolver F-01 a F-05.
- Executar testes de 16 KB em runtime, process death e permissao em API 24–36.
- Gerar AAB release assinado, obfuscado com `--split-debug-info`, guardar simbolos
  por versao e validar no internal testing.
- Confirmar autorizacao backend/IDOR com testes de duas contas e dois usuarios.

### Logo apos lancamento

- Implementar cursor/versionamento WebSocket, integration tests e observabilidade.
- Definir SLO de API/WS, alertas de 401/429/5xx, reconnect e upload falho.
- Migrar tela de rota/conclusao para controller/repository testavel.

### Melhorias futuras

- Outbox para operacoes explicitamente aprovadas como offline.
- SBOM, scanner continuo, flavors separados e atualizacao controlada dos plugins.
- Perfil em aparelhos de baixa memoria e redes degradadas.

## E. Matriz de testes

| Area | Cenarios obrigatorios | Estado |
| --- | --- | --- |
| Autenticacao | login, senha errada, token expirado, refresh rotacionado | parcial |
| Concorrencia auth | 50x401 -> 1 refresh; logout/troca de conta durante refresh | unitario parcial |
| REST | timeouts, DNS, TLS, 408/409/422/429/5xx, Retry-After | pendente |
| WebSocket | 4401, 4403, reset, jitter, heartbeat, payload invalido/grande | parcial |
| Eventos | duplicado, fora de ordem, perdido, 10 mil eventos | pendente |
| Offline | cada mutacao, fotos, retomada e conflitos | pendente |
| Lifecycle | resumed/inactive/hidden/paused/detached | codigo; dispositivo pendente |
| Process death | login, rota, foto, assinatura, upload parcial | pendente |
| Background | WebSocket parado, GPS parado, FCM | FCM pendente |
| Android | API 24, 29, 33, 35, 36; permissoes negadas | pendente |
| 16 KB | zipalign/ELF + boot real 16384 | estatico OK; runtime pendente |
| Memoria | abrir/fechar mapa/scanner; 5 fotos; heap estavel | pendente |
| Performance | cold/warm start, UI/raster jank, rede e bateria | pendente |
| Release | assinatura, HTTPS, AAB, R8, simbolos, update anterior | pendente |
| Privacidade | lock screen, logs, backup, troca de conta | parcial |

## F. Checklist final de producao

| Item | Estado | Observacao |
| --- | --- | --- |
| Analyzer limpo | ✅ OK | zero issues |
| Testes automatizados atuais | ✅ OK | suite passa |
| API 36 | ✅ OK | compile/target 36 |
| 16 KB zip/ELF | ✅ OK | estatico; runtime ainda pendente |
| HTTPS/WSS release | ✅ OK | guard Dart + Gradle + Manifest |
| Cleartext somente debug | ✅ OK | overlay explicito |
| JWT em secure storage | ✅ OK | flutter_secure_storage 10 |
| Single-flight refresh | ✅ OK | coberto por teste |
| Logout durante refresh | ✅ OK | resposta obsoleta descartada |
| Backup de sessao bloqueado | ✅ OK | backup/device transfer excluidos |
| WebSocket auth por header | ✅ OK | sem token na query |
| Heartbeat e timeout | ✅ OK | ping 25 s / connect 15 s |
| Backoff com jitter | ✅ OK | 0,5–32 s aproximado |
| Stop WS/GPS em background | ✅ OK | lifecycle observer |
| Upload key real | ❌ Bloqueia producao | nao fornecida |
| URL real de producao | ❌ Bloqueia producao | nao fornecida |
| Entrega idempotente/recuperavel | ❌ Bloqueia producao | F-03 |
| Push terminated | ❌ Bloqueia producao | F-04 |
| Politica/Data Safety | ❌ Bloqueia producao | F-05 |
| Autorizacao backend/IDOR | ❓ Nao verificavel | backend nao esta no workspace |
| Rotacao/reuse de refresh backend | ❓ Nao verificavel | configuracao backend ausente |
| Rate limiting backend | ❓ Nao verificavel | infraestrutura ausente |
| TLS do servidor | ❓ Nao verificavel | host de producao ausente |
| CI/CD | ⚠️ Precisa ajuste | inexistente |
| Observabilidade | ⚠️ Precisa ajuste | inexistente |
| Integration/chaos tests | ⚠️ Precisa ajuste | inexistentes |
| Offline/outbox | ⚠️ Precisa ajuste | inexistente |
| Cursor/versao WS | ⚠️ Precisa ajuste | contrato ausente |
| Flavors | ⚠️ Precisa ajuste | nenhum |
| SBOM/scanner | ⚠️ Precisa ajuste | nenhum |
| OAuth/OIDC/PKCE | ➖ Nao aplicavel | login JWT proprietario |
| WebView/deep link | ➖ Nao aplicavel | nao encontrados |
| Biometria/root/pinning | ➖ Nao aplicavel | threat model nao exige atualmente |
| Exclusao de conta no app | ❓ Nao verificavel | app nao cria conta; politica externa ausente |

## G. Patches aplicados nesta auditoria

- Refresh por instancia, single-flight, rotacao e geracao contra logout race.
- `sendTimeout` REST e cliente de refresh injetavel/testavel.
- HTTPS obrigatorio no release em Dart e Gradle.
- Release nunca mais usa signing debug e falha sem upload key.
- Backup/device transfer desativados.
- Background location/FGS sem uso removidos.
- WebSocket com jitter, limite de mensagem e parser isolado.
- WS e GPS controlados pelo lifecycle.
- Reconciliacao REST de notificacoes apos reconexao.
- Payload local de notificacao minimizado e lock screen privada.
- Dependencias e prototipos sem uso removidos.
- Testes de refresh concorrente, rotacao, logout race e URL release.

## H. Arquitetura recomendada

```text
UI
 |
 v
Feature Controller / StateNotifier / Cubit
 |
 v
Repository
 +-- LocalDataSource
 |    +-- cache persistente estritamente necessario
 |    +-- outbox cifrada e isolada por user/account
 |
 +-- RemoteDataSource
      +-- Dio / REST
      +-- RealtimeRepository
           +-- Connection Manager
           +-- Auth + heartbeat
           +-- backoff + jitter
           +-- cursor/version
           +-- snapshot REST de reconciliacao
```

REST permanece fonte de verdade. Eventos carregam identificador/versao e
invalidam entidades. Mutacoes criticas possuem operation ID idempotente e estado
duravel quando forem autorizadas para uso offline.

## I. Fluxo esperado de background

```text
FOREGROUND
  REST + WebSocket + GPS da rota ativa

PAUSED/HIDDEN
  fechar WebSocket e parar stream GPS
  receber apenas push de payload minimo

RESUMED
  restaurar sessao segura
  reconectar e autenticar WebSocket
  sincronizar por cursor ou snapshot REST
  reconciliar estado antes de aceitar novos eventos
```

## J. Fluxo de refresh implementado

```text
N requests -> 401
      |
      v
single-flight por ApiClient
      |
      +-- sucesso e mesma geracao de sessao
      |      -> salvar access/refresh rotacionado -> retry uma vez
      |
      +-- logout/troca de conta durante voo
      |      -> descartar resposta
      |
      +-- 400/401/403
             -> limpar sessao
```

## K. Fluxo WebSocket atual e recomendado

```text
START -> CONNECTING -> CONNECTED
          |               |
          |               +-- ping/pong 25 s
          |               +-- payload validado <= 256 KiB
          |               +-- eventos invalidam snapshot REST
          |
          +-- erro -> BACKOFF + JITTER (teto 32 s) -> retry

4401 -> um refresh -> reconnect
4403 -> parar
background/logout -> stop
resume -> start + snapshot REST

PENDENTE NO BACKEND: version + eventId + cursor/sync.
```

## Conclusao

**Eu aprovaria este aplicativo para producao? NAO.**

O codigo cliente esta mais seguro e previsivel apos os patches, mas assinatura,
ambiente real, privacidade, push terminated e atomicidade/recuperacao da entrega
sao requisitos externos ou arquiteturais ainda abertos. Depois de F-01 a F-05 e
da matriz minima de dispositivo serem comprovados, a classificacao pode mudar
para **SIM COM RESSALVAS**.

