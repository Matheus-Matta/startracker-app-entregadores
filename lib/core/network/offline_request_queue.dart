import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../storage/session_storage.dart';
import 'api_failure.dart';
import 'offline_request_store.dart';

export 'offline_request_store.dart' show PersistedOfflineRequest;

enum OfflineQueueEventType { queued, delivered, rejected }

class OfflineQueueEvent {
  const OfflineQueueEvent({
    required this.type,
    required this.resourceKey,
    required this.description,
    this.error,
    this.requestType,
    this.payload = const {},
    this.result,
  });

  final OfflineQueueEventType type;
  final String resourceKey;
  final String description;
  final Object? error;

  /// Tipo persistido (ex.: `mobile_sync.event`) e o que foi guardado.
  final String? requestType;
  final Map<String, dynamic> payload;

  /// Valor devolvido pela operação quando [type] é `delivered`.
  final Object? result;
}

/// Estado da fila exposto para a interface (banner de conexão).
@immutable
class OfflineQueueStatus {
  const OfflineQueueStatus({
    this.pendingCount = 0,
    this.rejectedCount = 0,
    this.attempts = 0,
    this.nextRetryAt,
    this.sending = false,
    this.needsLogin = false,
    this.description = '',
  });

  /// Ações do entregador atual aguardando envio.
  final int pendingCount;

  /// Ações recusadas pelo servidor, guardadas para o entregador decidir.
  final int rejectedCount;

  /// Tentativas seguidas sem conseguir falar com o servidor.
  final int attempts;
  final DateTime? nextRetryAt;
  final bool sending;

  /// A sessão expirou: o envio volta depois que o entregador entrar de novo.
  final bool needsLogin;
  final String description;

  bool get hasPending => pendingCount > 0;
  bool get needsAttention => rejectedCount > 0;
  bool get isVisible => hasPending || needsAttention;

  @override
  bool operator ==(Object other) =>
      other is OfflineQueueStatus &&
      other.pendingCount == pendingCount &&
      other.rejectedCount == rejectedCount &&
      other.attempts == attempts &&
      other.nextRetryAt == nextRetryAt &&
      other.sending == sending &&
      other.needsLogin == needsLogin &&
      other.description == description;

  @override
  int get hashCode => Object.hash(
    pendingCount,
    rejectedCount,
    attempts,
    nextRetryAt,
    sending,
    needsLogin,
    description,
  );
}

/// Registro da fila que não pôde ser reenviado depois de o app reabrir.
class OfflineRecordDiscarded implements Exception {
  const OfflineRecordDiscarded(this.reason);
  final String reason;

  @override
  String toString() =>
      'o registro salvo no aparelho estava danificado ($reason) e não pôde '
      'ser reenviado. Refaça a operação.';
}

class OfflineMutationResult<T> {
  const OfflineMutationResult.completed(this.value)
    : queued = false,
      savedOnDevice = true;
  const OfflineMutationResult.queued({this.savedOnDevice = true})
    : value = null,
      queued = true;

  final T? value;
  final bool queued;

  /// `false` quando o disco recusou a gravação (memória cheia): a ação só
  /// existe enquanto o app estiver aberto, e o entregador precisa saber.
  final bool savedOnDevice;
}

/// Visão somente leitura de uma ação guardada (pendente ou recusada).
class QueuedRequestInfo {
  const QueuedRequestInfo({
    required this.id,
    required this.resourceKey,
    required this.description,
    required this.createdAt,
    required this.type,
    required this.payload,
    this.rejection,
  });

  final String id;
  final String resourceKey;
  final String description;
  final DateTime createdAt;
  final String? type;
  final Map<String, dynamic> payload;
  final String? rejection;
}

typedef OfflineOperation<T> = Future<T> Function(String idempotencyKey);

/// Reconstrói uma operação persistida quando o app é reaberto.
typedef OfflineRestoreHandler =
    Future<dynamic> Function(
      String idempotencyKey,
      Map<String, dynamic> payload,
      Map<String, Uint8List> files,
    );

/// Fila de ações do entregador que precisam chegar ao servidor.
///
/// Regras:
/// * [enqueue] grava a ação no aparelho **antes** de tentar a rede: sem sinal
///   a tela responde na hora, e nada se perde se o sistema fechar o app;
/// * o envio é em ordem e nunca desiste: as tentativas seguem com intervalos
///   crescentes ([retryDelays]) e recomeçam quando o app volta à frente;
/// * recusa definitiva do servidor não apaga nada: a ação (com fotos) fica
///   em [rejectedRequests] até o entregador reenviar ou descartar;
/// * cada ação pertence ao entregador/conta que a fez: só é enviada na sessão
///   dele, e continua no aparelho depois de um logout.
class OfflineRequestQueue {
  OfflineRequestQueue(
    this._dio,
    this._storage, {
    OfflineRequestStore? store,
    this.retryDelays = defaultRetryDelays,
    this.serverErrorsBeforeSkip = 3,
    DateTime Function()? clock,
  }) : _store = store ?? OfflineRequestStore(),
       _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const defaultRetryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  final Dio _dio;
  final SessionStorage _storage;
  final OfflineRequestStore _store;
  final List<Duration> retryDelays;

  /// Erros 5xx seguidos na mesma ação antes de ela ir para o fim da fila.
  final int serverErrorsBeforeSkip;

  final Queue<_PendingRequest<dynamic>> _pending = Queue();
  final List<_PendingRequest<dynamic>> _rejected = [];
  final Map<String, OfflineRestoreHandler> _handlers = {};
  final Map<String, Completer<Object?>> _waiters = {};
  final StreamController<OfflineQueueEvent> _events =
      StreamController<OfflineQueueEvent>.broadcast();
  late final ValueNotifier<OfflineQueueStatus> status = ValueNotifier(
    const OfflineQueueStatus(),
  );

  /// Sem sonda se o servidor respondeu dentro desta janela.
  static const recentContactWindow = Duration(seconds: 30);

  /// Ação nova não dispara tentativa se a rede falhou há menos disto: o
  /// timer já cuida do reenvio e a tela não espera uma tentativa fadada.
  static const offlineQuietWindow = Duration(seconds: 15);

  DateTime? _lastContactAt;
  DateTime? _lastNetworkStallAt;

  bool get _recentlyOffline =>
      _lastNetworkStallAt != null &&
      DateTime.now().difference(_lastNetworkStallAt!) < offlineQuietWindow;

  Timer? _retryTimer;
  DateTime? _nextRetryAt;
  bool _draining = false;
  bool _drainAgain = false;
  bool _needsLogin = false;
  bool _restored = false;
  bool _disposed = false;
  int _failures = 0;
  int _sequence = 0;
  String? _owner;
  bool _ownerKnown = false;

  Stream<OfflineQueueEvent> get events => _events.stream;
  int get pendingCount => _mine(_pending).length;

  /// Ações pendentes do entregador atual, na ordem em que foram feitas.
  List<QueuedRequestInfo> get pendingRequests =>
      _mine(_pending).map((item) => item.info).toList(growable: false);

  /// Ações recusadas do entregador atual.
  List<QueuedRequestInfo> get rejectedRequests =>
      _mine(_rejected).map((item) => item.info).toList(growable: false);

  /// Falha transitória de transporte: a requisição deve ser guardada e
  /// reenviada, nunca descartada.
  ///
  /// Em dados móveis a conexão costuma cair no meio do upload
  /// (`HttpException: Connection closed...`), o TLS é interrompido
  /// (`HandshakeException`) ou o Cloudflare responde com erro de gateway ou
  /// desafio anti-bot para IPs compartilhados de operadora.
  static bool isNetworkFailure(DioException error) {
    if (error.type == DioExceptionType.cancel) return false;
    final response = error.response;
    final status = response?.statusCode ?? 0;
    // Portal da operadora/Wi-Fi ou corpo truncado: a requisição pode não ter
    // chegado à API. Reenviar com a mesma chave de idempotência é seguro.
    if (error.error is UnexpectedResponseFormat ||
        (error.error is FormatException && (status == 0 || status < 300))) {
      return true;
    }
    if (response != null) return isTransientResponse(response);
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return true;
    }
    final cause = error.error;
    // IOException cobre SocketException, HttpException e TlsException.
    return cause is IOException || cause is TimeoutException;
  }

  /// Respostas que não vieram da API, e sim de proxy/CDN no caminho.
  static bool isTransientResponse(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    if (response.headers.value('cf-mitigated') != null) return true;
    return status == 408 ||
        status == 429 ||
        status == 502 ||
        status == 503 ||
        status == 504 ||
        (status >= 520 && status <= 530);
  }

  /// Registra como reconstruir requisições do tipo [type] salvas em disco.
  void registerRestoreHandler(String type, OfflineRestoreHandler handler) {
    _handlers[type] = handler;
  }

  final Map<String, Future<void> Function(Map<String, dynamic>, Object?)>
  _deliveredHooks = {};

  /// Roda (e é aguardado) quando o servidor confirma uma ação de [type],
  /// **antes** de a ação sair do disco: se o app for morto nesse instante,
  /// ou a confirmação já foi registrada, ou a ação ainda está na fila e é
  /// reenviada (o servidor devolve o mesmo resultado). Nunca os dois perdidos.
  void registerDeliveredHook(
    String type,
    Future<void> Function(Map<String, dynamic> payload, Object? result) hook,
  ) {
    _deliveredHooks[type] = hook;
  }

  /// Carrega do disco o que ficou pendente (app reaberto, login de novo).
  ///
  /// Fotos e assinatura não são lidas aqui: com dezenas de baixas sem sinal
  /// isso enchia a memória. Cada anexo é lido do disco só na hora do envio.
  Future<void> restorePersisted() async {
    if (_restored) return;
    _restored = true;
    await _refreshOwner();
    List<StoredOfflineRequest> stored;
    try {
      stored = await _store.readAll();
    } catch (error) {
      _restored = false;
      _logUnexpected('Reabrir fila offline', error);
      return;
    }
    for (final lost in _store.lastDiscarded) {
      ApiFailureLog.instance.record(
        ApiFailure(
          stage: 'Reabrir fila offline',
          kind: ApiFailureKind.unknown,
          detail: '${lost.description}: ${lost.reason}',
        ),
      );
      _emit(
        OfflineQueueEvent(
          type: OfflineQueueEventType.rejected,
          resourceKey: lost.resourceKey,
          description: lost.description,
          error: OfflineRecordDiscarded(lost.reason),
        ),
      );
    }
    final known = {
      for (final item in _pending) item.id,
      for (final item in _rejected) item.id,
      // Sendo enviada agora (troca de sessão no meio do envio): relê-la do
      // disco faria um segundo envio da mesma ação.
      ..._sendingIds,
    };
    for (final item in stored) {
      _noteCreatedAt(item.createdAt);
      if (known.contains(item.id)) continue;
      final handler = _handlers[item.request.type];
      // Sem quem saiba enviar (tipo de outra versão do app): fica no disco,
      // nunca é apagado sem o entregador ver.
      if (handler == null) continue;
      final request = _PendingRequest<Object?>(
        id: item.id,
        resourceKey: item.resourceKey,
        description: item.description,
        idempotencyKey: item.idempotencyKey,
        createdAt: item.createdAt,
        owner: item.owner,
        sessionGeneration: _storage.identityGeneration,
        persisted: item.request,
        operation: _lazyOperation(item.id, item.request, handler),
      )..rejection = item.rejection;
      if (item.rejection == null) {
        _pending.add(request);
      } else {
        _rejected.add(request);
      }
    }
    if (_sendable().isNotEmpty) _scheduleRetry(immediate: true);
    _publish();
  }

  /// Maior `createdAt` já usado. A fila reaberta é ordenada por ele: com o
  /// relógio do celular voltando (hora ajustada quando o sinal volta),
  /// "iniciar entrega" passava à frente de "cheguei" e o servidor ignorava
  /// o início.
  DateTime? _lastCreatedAt;

  DateTime _nextCreatedAt() {
    final now = _clock();
    final last = _lastCreatedAt;
    final next = last != null && !now.isAfter(last)
        ? last.add(const Duration(milliseconds: 1))
        : now;
    return _lastCreatedAt = next;
  }

  void _noteCreatedAt(DateTime createdAt) {
    final last = _lastCreatedAt;
    if (last == null || createdAt.isAfter(last)) _lastCreatedAt = createdAt;
  }

  /// Operação que lê os anexos do disco só quando vai enviar.
  OfflineOperation<Object?> _lazyOperation(
    String id,
    PersistedOfflineRequest request,
    OfflineRestoreHandler handler,
  ) =>
      (key) async => handler(
        key,
        request.payload,
        request.hasFiles ? await _store.readFiles(id) : const {},
      );

  /// Troca de sessão (logout/login): esquece a memória e relê o disco.
  ///
  /// Nada é apagado do aparelho: o que pertence a outro entregador fica
  /// guardado e volta a ser enviado quando ele entrar de novo.
  Future<void> reloadSession() async {
    _cancelTimer();
    _pending.clear();
    _rejected.clear();
    _failures = 0;
    _needsLogin = false;
    _restored = false;
    _ownerKnown = false;
    _publish();
    await restorePersisted();
  }

  /// Grava a ação no aparelho e agenda o envio, sem esperar a rede.
  ///
  /// Com [waitFor], espera até esse tempo pelo envio: online, o chamador
  /// recebe a resposta do servidor (e uma recusa vira exceção, com a ação
  /// descartada da fila porque o entregador ainda está na tela para
  /// corrigir); sem sinal, recebe `queued` e a ação segue na fila.
  Future<OfflineMutationResult<T>> enqueue<T>({
    required String resourceKey,
    required String description,
    required PersistedOfflineRequest persisted,
    required OfflineOperation<T> operation,
    Duration? waitFor,
  }) async {
    await _refreshOwner();
    final id = newEventId();
    final request = _PendingRequest<T>(
      id: id,
      resourceKey: resourceKey,
      description: description,
      idempotencyKey: id,
      createdAt: _nextCreatedAt(),
      owner: _owner,
      sessionGeneration: _storage.identityGeneration,
      persisted: persisted,
      operation: operation,
    );
    var saved = false;
    try {
      await _store.save(request.toStored());
      saved = true;
      // Gravado: as fotos saem da memória e são relidas do disco no envio.
      final handler = _handlers[persisted.type];
      if (persisted.files.isNotEmpty && handler != null) {
        final lazy = _lazyOperation(id, persisted.withoutFiles(), handler);
        request
          ..persisted = persisted.withoutFiles()
          ..operation = (key) async => (await lazy(key)) as T;
      }
    } catch (error) {
      // Sem disco a ação continua na fila em memória (e fica registrado).
      _logUnexpected('Salvar ação no aparelho', error);
    }
    _pending.add(request);
    _emit(request.event(OfflineQueueEventType.queued));
    _publish();
    if (_recentlyOffline) {
      // Sem sinal há instantes: nada de nova tentativa a cada toque (cada
      // uma é uma conexão e bateria). Mas a próxima fica em no máximo
      // [offlineQuietWindow]: depois de horas sem sinal o intervalo chegava
      // a 5 min, e a ação feita logo que o sinal voltou esperava tudo isso.
      _scheduleRetry(maxDelay: offlineQuietWindow);
      return OfflineMutationResult<T>.queued(savedOnDevice: saved);
    }
    if (waitFor == null) {
      unawaited(_drain());
      return OfflineMutationResult<T>.queued(savedOnDevice: saved);
    }
    final waiter = Completer<Object?>();
    _waiters[id] = waiter;
    unawaited(_drain());
    try {
      final value = await waiter.future.timeout(waitFor);
      if (identical(value, _stillQueued)) {
        return OfflineMutationResult<T>.queued(savedOnDevice: saved);
      }
      return OfflineMutationResult<T>.completed(value as T);
    } on TimeoutException {
      return OfflineMutationResult<T>.queued(savedOnDevice: saved);
    } on _RejectedWhileWaiting catch (rejected) {
      await discardRejected(id);
      throw rejected.error;
    } finally {
      _waiters.remove(id);
    }
  }

  /// Tenta online primeiro; só sem rede a ação vai para a fila.
  ///
  /// Mantido para operações que dependem do servidor para fazer sentido
  /// (ex.: preparar a rota, que precisa do roteirizador).
  Future<OfflineMutationResult<T>> execute<T>({
    required String resourceKey,
    required String description,
    required OfflineOperation<T> operation,
    PersistedOfflineRequest? persisted,
  }) async {
    final idempotencyKey = newEventId();
    try {
      return OfflineMutationResult<T>.completed(
        await operation(idempotencyKey),
      );
    } on DioException catch (error) {
      if (!isNetworkFailure(error)) rethrow;
      await _refreshOwner();
      final request = _PendingRequest<T>(
        id: idempotencyKey,
        resourceKey: resourceKey,
        description: description,
        idempotencyKey: idempotencyKey,
        createdAt: _nextCreatedAt(),
        owner: _owner,
        sessionGeneration: _storage.identityGeneration,
        persisted: persisted,
        operation: operation,
      );
      _pending.add(request);
      if (persisted != null) {
        try {
          await _store.save(request.toStored());
        } catch (_) {}
      }
      _emit(request.event(OfflineQueueEventType.queued));
      _scheduleRetry();
      _publish();
      return OfflineMutationResult<T>.queued();
    }
  }

  Options requestOptions(
    String idempotencyKey, {
    String? step,
    String? stage,
    bool upload = false,
  }) => Options(
    extra: {ApiFailure.stageKey: ?stage},
    headers: {
      'Idempotency-Key': step == null
          ? idempotencyKey
          : '$idempotencyKey-$step',
    },
    // Fotos e assinatura em dados móveis: o upload inteiro precisa caber no
    // sendTimeout e o servidor ainda grava o arquivo antes de responder.
    sendTimeout: upload ? const Duration(minutes: 3) : null,
    receiveTimeout: upload ? const Duration(seconds: 90) : null,
  );

  /// Tenta enviar a fila agora (botão, app voltou à frente, rede voltou).
  Future<void> retryNow({bool manual = false}) async {
    if (manual) _failures = 0;
    // Pedido explícito (botão, app voltou à frente): tenta de verdade.
    _lastNetworkStallAt = null;
    await _drain();
  }

  /// Envia agora e espera o envio terminar, até [timeout].
  ///
  /// Com [resourceKey], só importa o que é desse alvo (ex.: as leituras da
  /// conferência `wave:<id>`). `true` quando nada dele ficou na fila; sem
  /// sinal devolve `false` logo que o envio para, e a fila segue sozinha.
  Future<bool> flush({
    String? resourceKey,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    bool done() => !_mine(
      _pending,
    ).any((item) => resourceKey == null || item.resourceKey == resourceKey);
    if (done()) return true;
    try {
      await retryNow().timeout(timeout);
    } on TimeoutException {
      // Envio longo (fotos no 4G): segue em segundo plano.
    }
    return done();
  }

  /// Devolve uma ação recusada para a fila de envio.
  Future<void> retryRejected(String id) async {
    final request = _rejected.where((item) => item.id == id).firstOrNull;
    if (request == null) return;
    _rejected.remove(request);
    request
      ..rejection = null
      ..serverErrors = 0;
    _pending.add(request);
    // A tela reflete na hora; o disco acompanha (um toque duplo no botão não
    // encontra mais o item como recusado).
    _publish();
    await _store.clearRejection(id);
    await _drain();
  }

  /// Descarta de vez uma ação recusada (decisão do entregador).
  Future<void> discardRejected(String id) async {
    _rejected.removeWhere((item) => item.id == id);
    _publish();
    await _store.delete(id);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final wake = _wakeSend;
    if (wake != null && !wake.isCompleted) wake.complete();
    _pending.clear();
    _rejected.clear();
    _cancelTimer();
    unawaited(_events.close());
    status.dispose();
  }

  /// Envio em andamento; quem pede outro espera este (e o seguinte).
  Future<void>? _inFlight;

  /// Ações sendo enviadas neste instante (a fila e a via das fotos).
  final Set<String> _sendingIds = {};

  /// Acorda o envio que espera os uploads quando chega ação nova.
  Completer<void>? _wakeSend;

  Future<void> _drain() {
    if (_disposed) return Future.value();
    final current = _inFlight;
    if (current != null) {
      // Já enviando: marca para rodar de novo e espera junto, em vez de
      // abrir um segundo envio em paralelo (que duplicaria requisições).
      _drainAgain = true;
      final wake = _wakeSend;
      if (wake != null && !wake.isCompleted) wake.complete();
      return current.then((_) => _inFlight ?? Future<void>.value());
    }
    final run = _drainOnce();
    _inFlight = run;
    return run.whenComplete(() {
      if (identical(_inFlight, run)) _inFlight = null;
    });
  }

  Future<void> _drainOnce() async {
    if (_sendable().isEmpty) {
      _publish();
      return;
    }
    _draining = true;
    _cancelTimer();
    _publish();
    var stalled = false;
    try {
      stalled = !await _sendAll();
    } catch (error) {
      // Nada pode parar a fila de vez: erro inesperado vira nova tentativa.
      stalled = true;
      _logUnexpected('Enviar fila', error);
    } finally {
      _draining = false;
      if (stalled) {
        _failures++;
        // Sem rede quem espera a resposta segue com "salvo no aparelho" na
        // hora, em vez de esperar o tempo limite inteiro.
        for (final waiter in _waiters.values) {
          if (!waiter.isCompleted) waiter.complete(_stillQueued);
        }
      }
      final again = _drainAgain;
      _drainAgain = false;
      if (!_disposed && _sendable().isNotEmpty) {
        if (again && !stalled) {
          // Chegou ação nova durante o envio: segue logo depois deste.
          scheduleMicrotask(() => unawaited(_drain()));
        } else {
          _scheduleRetry();
        }
      }
      _publish();
    }
  }

  /// Envia em ordem. `false` quando parou antes do fim (sem rede, sessão
  /// expirada ou servidor com erro): a fila agenda nova tentativa.
  ///
  /// Ações com anexo (fotos da baixa) sobem numa via própria, uma por vez e
  /// na ordem: no 4G fraco o upload levava dezenas de segundos e segurava
  /// tudo atrás dele. Só passam na frente as ações de outra parada
  /// ([_mayPassUploads]); as demais (iniciar rota, retirada) esperam os
  /// uploads anteriores, porque podem depender deles no servidor.
  Future<bool> _sendAll() async {
    await _refreshOwner();
    // Com contato recente a sonda só somava uma ida e volta (300 ms ou mais
    // no 4G) antes de cada ação; se a rede caiu, o próprio envio detecta.
    final recent =
        _lastContactAt != null &&
        DateTime.now().difference(_lastContactAt!) < recentContactWindow;
    if (!recent && !await _apiIsReachable()) {
      _lastNetworkStallAt = DateTime.now();
      return false;
    }
    _needsLogin = false;
    final uploads = <_PendingRequest<dynamic>>[];
    // Paradas com foto ainda não enviada nesta rodada (na via ou paradas).
    final unsentUploadKeys = <String>[];
    Future<void>? uploading;
    var uploadsStalled = false;
    var serverTrouble = false;

    Future<void> runUploads() async {
      try {
        while (uploads.isNotEmpty) {
          final result = await _sendOne(uploads.first);
          if (result == _SendOutcome.stalled) {
            uploadsStalled = true;
            uploads.clear();
            return;
          }
          final done = uploads.removeAt(0);
          if (result == _SendOutcome.movedToEnd) {
            // Foi para o fim sem chegar: a mesma parada continua esperando.
            serverTrouble = true;
          } else {
            unsentUploadKeys.remove(done.resourceKey);
          }
        }
      } finally {
        uploading = null;
      }
    }

    /// Espera os uploads em andamento; `false` se pararam sem terminar.
    Future<bool> finishUploads() async {
      for (var running = uploading; running != null; running = uploading) {
        await running;
      }
      return !uploadsStalled;
    }

    final visited = <String>{};
    try {
      while (true) {
        if (_disposed) return false;
        _PendingRequest<dynamic>? request;
        for (final item in _sendable()) {
          if (!visited.contains(item.id)) {
            request = item;
            break;
          }
        }
        if (request == null) {
          final running = uploading;
          if (running == null) break;
          // Fotos subindo: uma ação feita agora sai já, sem esperar o fim
          // do upload (antes ficava para a rodada seguinte).
          final wake = _wakeSend = Completer<void>();
          await Future.any([running, wake.future]);
          _wakeSend = null;
          continue;
        }
        visited.add(request.id);
        if (request.persisted == null &&
            request.sessionGeneration != _storage.identityGeneration) {
          _pending.remove(request);
          continue;
        }
        if (request.persisted?.hasFiles ?? false) {
          unsentUploadKeys.add(request.resourceKey);
          // Upload que parou: os seguintes esperam a próxima tentativa.
          if (uploadsStalled) continue;
          uploads.add(request);
          uploading ??= runUploads();
          continue;
        }
        final passes =
            _mayPassUploads(request.resourceKey) &&
            !unsentUploadKeys.contains(request.resourceKey);
        if (!passes && !await finishUploads()) return false;
        final result = await _sendOne(request);
        if (result == _SendOutcome.stalled) return false;
        if (result == _SendOutcome.movedToEnd) serverTrouble = true;
      }
    } finally {
      await finishUploads();
    }
    return !serverTrouble && !uploadsStalled;
  }

  /// Ação sem anexo que pode ser enviada antes de uploads pendentes: a de
  /// uma parada (baixa sem foto, falha) não depende da baixa de outra.
  static bool _mayPassUploads(String resourceKey) =>
      resourceKey.startsWith('stop:');

  Future<_SendOutcome> _sendOne(_PendingRequest<dynamic> request) async {
    if (_disposed) return _SendOutcome.stalled;
    _sendingIds.add(request.id);
    try {
      final value = await request.operation(request.idempotencyKey);
      _lastContactAt = DateTime.now();
      final hook = _deliveredHooks[request.persisted?.type];
      if (hook != null) {
        try {
          await hook(request.persisted?.payload ?? const {}, value);
        } catch (error) {
          _logUnexpected('Registrar confirmação', error);
        }
      }
      _pending.remove(request);
      // Sem esperar o disco: apagar a pasta (com as fotos) segurava o envio
      // seguinte. Se o app morrer antes, a ação é reenviada e o servidor
      // reconhece a repetição pelo id.
      unawaited(_store.delete(request.id));
      _failures = 0;
      request.serverErrors = 0;
      final waiter = _waiters[request.id];
      if (waiter != null && !waiter.isCompleted) waiter.complete(value);
      _emit(request.event(OfflineQueueEventType.delivered, result: value));
      _publish();
      return _SendOutcome.sent;
    } on DioException catch (error) {
      final status = error.response?.statusCode ?? 0;
      if (isNetworkFailure(error)) {
        _lastContactAt = null;
        _lastNetworkStallAt = DateTime.now();
        _keepPending(request);
        return _SendOutcome.stalled;
      }
      if (status == 401) {
        // Refresh recusado: espera o entregador entrar de novo.
        _needsLogin = true;
        _keepPending(request);
        return _SendOutcome.stalled;
      }
      if (status >= 500) {
        // Erro do servidor nunca descarta. As primeiras vezes seguram a
        // fila (pode ser um deploy); se persistir, a ação vai para o fim
        // e as outras seguem — uma ação problemática não trava as demais.
        if (++request.serverErrors < serverErrorsBeforeSkip) {
          _keepPending(request);
          return _SendOutcome.stalled;
        }
        _pending
          ..remove(request)
          ..add(request);
        return _SendOutcome.movedToEnd;
      }
      await _reject(request, error);
      return _SendOutcome.sent;
    } catch (error) {
      // Erro local determinístico (anexo apagado, resposta inválida):
      // repetir não resolve; fica para o entregador decidir.
      await _reject(request, error);
      return _SendOutcome.sent;
    } finally {
      _sendingIds.remove(request.id);
    }
  }

  /// O envio não terminou: a ação continua na fila. Se a sessão foi trocada
  /// no meio do envio, a releitura do disco pulou esta ação (estava sendo
  /// enviada) e a memória tinha sido limpa — sem isto ela sumia até o app
  /// reabrir.
  void _keepPending(_PendingRequest<dynamic> request) {
    if (_disposed ||
        _pending.contains(request) ||
        _rejected.contains(request)) {
      return;
    }
    if (_pending.any((item) => item.id == request.id)) return;
    _pending.addFirst(request);
  }

  Future<void> _reject(_PendingRequest<dynamic> request, Object error) async {
    _pending.remove(request);
    final waiter = _waiters[request.id];
    if (request.persisted != null) {
      request.rejection = describeFailure(error);
      // Primeiro no disco: se o app fechar agora, a recusa continua lá.
      await _store.markRejected(request.id, request.rejection!);
      _rejected.add(request);
    }
    waiter?.completeError(_RejectedWhileWaiting(error));
    _emit(request.event(OfflineQueueEventType.rejected, error: error));
    _publish();
  }

  Future<bool> _apiIsReachable() async {
    try {
      await _dio.get<dynamic>(
        '/api/v1/',
        options: Options(
          validateStatus: (status) => status != null,
          // A sonda decide rápido se vale drenar a fila; sem repetição e sem
          // poluir o histórico de falhas.
          extra: const {'noReadRetry': true, 'noFailureLog': true},
        ),
      );
      _lastContactAt = DateTime.now();
      return true;
    } on DioException catch (error) {
      final reachable = !isNetworkFailure(error);
      if (reachable) _lastContactAt = DateTime.now();
      return reachable;
    }
  }

  void _scheduleRetry({bool immediate = false, Duration? maxDelay}) {
    if (_disposed) return;
    final index = (_failures - 1).clamp(0, retryDelays.length - 1);
    var delay = immediate || _failures == 0
        ? const Duration(seconds: 2)
        : retryDelays[index];
    if (maxDelay != null && delay > maxDelay) delay = maxDelay;
    final scheduled = _nextRetryAt;
    if (_retryTimer != null) {
      // Já agendado: só antecipa, nunca adia.
      if (scheduled == null || !scheduled.isAfter(DateTime.now().add(delay))) {
        return;
      }
      _cancelTimer();
    }
    _nextRetryAt = DateTime.now().add(delay);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _nextRetryAt = null;
      unawaited(_drain());
    });
    // O banner mostra "nova tentativa em…": sem publicar, ele continuava
    // com o horário antigo quando a tentativa era antecipada.
    _publish();
  }

  void _cancelTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _nextRetryAt = null;
  }

  Future<void> _refreshOwner() async {
    try {
      _owner = await _storage.readIdentity();
    } catch (_) {
      _owner = null;
    }
    _ownerKnown = true;
  }

  /// O que aparece para a sessão atual (sem sessão, mostra tudo).
  Iterable<_PendingRequest<dynamic>> _mine(
    Iterable<_PendingRequest<dynamic>> items,
  ) => items.where(
    (item) =>
        !_ownerKnown ||
        item.owner == null ||
        _owner == null ||
        item.owner == _owner,
  );

  /// O que pode ser enviado agora: só com a sessão de quem fez a ação.
  Iterable<_PendingRequest<dynamic>> _sendable() => _pending.where(
    (item) => item.owner == null || (_owner != null && item.owner == _owner),
  );

  void _logUnexpected(String stage, Object error) {
    try {
      ApiFailureLog.instance.record(
        ApiFailure(
          stage: stage,
          kind: ApiFailureKind.unknown,
          detail: error.toString(),
        ),
      );
    } catch (_) {}
  }

  void _publish() {
    if (_disposed) return;
    final mine = _mine(_pending);
    final head = mine.isEmpty ? null : mine.first;
    status.value = OfflineQueueStatus(
      pendingCount: mine.length,
      rejectedCount: _mine(_rejected).length,
      attempts: _failures,
      nextRetryAt: _nextRetryAt,
      sending: _draining,
      needsLogin: _needsLogin,
      description: head?.description ?? '',
    );
  }

  void _emit(OfflineQueueEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Identificador único da ação, gerado no aparelho.
  ///
  /// Vai para o servidor como `client_event_id`/`Idempotency-Key`: o mesmo
  /// valor em todos os reenvios, inclusive depois de o app ser reaberto.
  String newEventId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final noise = _random.nextInt(1 << 32).toRadixString(36);
    return 'mobile-$now-${_sequence++}-$noise';
  }

  static final Random _random = _secureRandom();

  static Random _secureRandom() {
    try {
      return Random.secure();
    } catch (_) {
      return Random();
    }
  }
}

const _stillQueued = Object();

/// Resultado de um envio: [stalled] mantém a ação e para esta rodada;
/// [movedToEnd] é o 5xx persistente que foi para o fim da fila.
enum _SendOutcome { sent, stalled, movedToEnd }

class _RejectedWhileWaiting implements Exception {
  const _RejectedWhileWaiting(this.error);
  final Object error;
}

class _PendingRequest<T> {
  _PendingRequest({
    required this.id,
    required this.resourceKey,
    required this.description,
    required this.idempotencyKey,
    required this.createdAt,
    required this.owner,
    required this.sessionGeneration,
    required this.persisted,
    required this.operation,
  });

  final String id;
  final String resourceKey;
  final String description;
  final String idempotencyKey;
  final DateTime createdAt;
  final String? owner;
  final int sessionGeneration;
  PersistedOfflineRequest? persisted;
  OfflineOperation<T> operation;
  int serverErrors = 0;
  String? rejection;

  QueuedRequestInfo get info => QueuedRequestInfo(
    id: id,
    resourceKey: resourceKey,
    description: description,
    createdAt: createdAt,
    type: persisted?.type,
    payload: persisted?.payload ?? const {},
    rejection: rejection,
  );

  StoredOfflineRequest toStored() => StoredOfflineRequest(
    id: id,
    resourceKey: resourceKey,
    description: description,
    idempotencyKey: idempotencyKey,
    createdAt: createdAt,
    request: persisted!,
    owner: owner,
  );

  OfflineQueueEvent event(
    OfflineQueueEventType type, {
    Object? error,
    Object? result,
  }) => OfflineQueueEvent(
    type: type,
    resourceKey: resourceKey,
    description: description,
    error: error,
    requestType: persisted?.type,
    payload: persisted?.payload ?? const {},
    result: result,
  );
}
