import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../storage/session_storage.dart';
import 'offline_request_store.dart';

export 'offline_request_store.dart' show PersistedOfflineRequest;

enum OfflineQueueEventType { queued, delivered, rejected, exhausted }

class OfflineQueueEvent {
  const OfflineQueueEvent({
    required this.type,
    required this.resourceKey,
    required this.description,
    this.error,
  });

  final OfflineQueueEventType type;
  final String resourceKey;
  final String description;
  final Object? error;
}

/// Estado da fila exposto para a interface (banner de conexão).
@immutable
class OfflineQueueStatus {
  const OfflineQueueStatus({
    this.pendingCount = 0,
    this.attempts = 0,
    this.maxAttempts = 3,
    this.nextRetryAt,
    this.sending = false,
    this.exhausted = false,
    this.description = '',
  });

  final int pendingCount;

  /// Tentativas automáticas já feitas para a primeira requisição da fila.
  final int attempts;
  final int maxAttempts;
  final DateTime? nextRetryAt;
  final bool sending;

  /// As tentativas automáticas acabaram; só um reenvio manual continua.
  final bool exhausted;
  final String description;

  bool get hasPending => pendingCount > 0;

  @override
  bool operator ==(Object other) =>
      other is OfflineQueueStatus &&
      other.pendingCount == pendingCount &&
      other.attempts == attempts &&
      other.maxAttempts == maxAttempts &&
      other.nextRetryAt == nextRetryAt &&
      other.sending == sending &&
      other.exhausted == exhausted &&
      other.description == description;

  @override
  int get hashCode => Object.hash(
    pendingCount,
    attempts,
    maxAttempts,
    nextRetryAt,
    sending,
    exhausted,
    description,
  );
}

class OfflineMutationResult<T> {
  const OfflineMutationResult.completed(this.value) : queued = false;
  const OfflineMutationResult.queued() : value = null, queued = true;

  final T? value;
  final bool queued;
}

typedef OfflineOperation<T> = Future<T> Function(String idempotencyKey);

/// Reconstrói uma operação persistida quando o app é reaberto.
typedef OfflineRestoreHandler =
    Future<void> Function(
      String idempotencyKey,
      Map<String, dynamic> payload,
      Map<String, Uint8List> files,
    );

/// Fila de requisições que falharam por falta de rede.
///
/// Regras:
/// * a requisição que falhou é guardada (em memória e em disco, quando há
///   descrição persistível) e reenviada automaticamente a cada [retryInterval];
/// * cada requisição tem no máximo [maxAttempts] tentativas automáticas;
/// * esgotadas as tentativas, a fila para e avisa a interface. Nada é
///   descartado: o entregador pode reenviar manualmente ([retryNow] com
///   `manual: true`) e a fila também é retomada quando o app é reaberto.
class OfflineRequestQueue {
  OfflineRequestQueue(
    this._dio,
    this._storage, {
    OfflineRequestStore? store,
    this.retryInterval = const Duration(minutes: 1),
    this.maxAttempts = 3,
  }) : _store = store ?? OfflineRequestStore();

  final Dio _dio;
  final SessionStorage _storage;
  final OfflineRequestStore _store;
  final Duration retryInterval;
  final int maxAttempts;
  final Queue<_PendingRequest<dynamic>> _pending = Queue();
  final Map<String, OfflineRestoreHandler> _handlers = {};
  final StreamController<OfflineQueueEvent> _events =
      StreamController<OfflineQueueEvent>.broadcast();
  late final ValueNotifier<OfflineQueueStatus> status = ValueNotifier(
    OfflineQueueStatus(maxAttempts: maxAttempts),
  );

  Timer? _retryTimer;
  DateTime? _nextRetryAt;
  bool _retrying = false;
  bool _exhausted = false;
  bool _restored = false;
  int _sequence = 0;

  Stream<OfflineQueueEvent> get events => _events.stream;
  int get pendingCount => _pending.length;

  /// Falha transitória de transporte: a requisição deve ser guardada e
  /// reenviada, nunca descartada.
  ///
  /// Em dados móveis a conexão costuma cair no meio do upload
  /// (`HttpException: Connection closed...`), o TLS é interrompido
  /// (`HandshakeException`) ou o Cloudflare responde com erro de gateway ou
  /// desafio anti-bot para IPs compartilhados de operadora. Antes esses casos
  /// eram tratados como erro definitivo e a entrega era perdida.
  static bool isNetworkFailure(DioException error) {
    if (error.type == DioExceptionType.cancel) return false;
    final response = error.response;
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

  /// Recarrega requisições que ficaram pendentes antes do app ser encerrado.
  Future<void> restorePersisted() async {
    if (_restored) return;
    _restored = true;
    List<StoredOfflineRequest> stored;
    try {
      stored = await _store.readAll();
    } catch (_) {
      return;
    }
    final known = _pending.map((item) => item.id).toSet();
    for (final item in stored) {
      if (known.contains(item.id)) continue;
      final handler = _handlers[item.request.type];
      if (handler == null) {
        await _store.delete(item.id);
        continue;
      }
      _pending.add(
        _PendingRequest<void>(
          id: item.id,
          resourceKey: item.resourceKey,
          description: item.description,
          idempotencyKey: item.idempotencyKey,
          sessionGeneration: _storage.identityGeneration,
          persisted: true,
          operation: (key) =>
              handler(key, item.request.payload, item.request.files),
        ),
      );
    }
    if (_pending.isNotEmpty) {
      _exhausted = false;
      _scheduleRetry(immediate: true);
    }
    _publish();
  }

  Future<OfflineMutationResult<T>> execute<T>({
    required String resourceKey,
    required String description,
    required OfflineOperation<T> operation,
    PersistedOfflineRequest? persisted,
  }) async {
    final idempotencyKey = _newIdempotencyKey();
    try {
      return OfflineMutationResult<T>.completed(
        await operation(idempotencyKey),
      );
    } on DioException catch (error) {
      if (!isNetworkFailure(error)) rethrow;
      final request = _PendingRequest<T>(
        id: idempotencyKey,
        resourceKey: resourceKey,
        description: description,
        idempotencyKey: idempotencyKey,
        sessionGeneration: _storage.identityGeneration,
        persisted: persisted != null,
        operation: operation,
      );
      _pending.add(request);
      if (persisted != null) {
        try {
          await _store.save(
            StoredOfflineRequest(
              id: request.id,
              resourceKey: resourceKey,
              description: description,
              idempotencyKey: idempotencyKey,
              createdAt: DateTime.now(),
              request: persisted,
            ),
          );
        } catch (_) {
          // Sem disco a requisição continua na fila em memória.
        }
      }
      _emit(
        OfflineQueueEvent(
          type: OfflineQueueEventType.queued,
          resourceKey: resourceKey,
          description: description,
        ),
      );
      // Uma nova falha reabre a fila, mesmo que a anterior tenha esgotado.
      if (_exhausted) {
        _exhausted = false;
        for (final item in _pending) {
          item.attempts = 0;
        }
      }
      _scheduleRetry();
      _publish();
      return OfflineMutationResult<T>.queued();
    }
  }

  Options requestOptions(
    String idempotencyKey, {
    String? step,
    bool upload = false,
  }) => Options(
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

  /// Tenta enviar a fila agora.
  ///
  /// * `manual: true` (botão "Tentar novamente"): zera o contador de
  ///   tentativas e reabre a fila esgotada.
  /// * chamadas oportunistas (app voltou ao primeiro plano, websocket
  ///   reconectou) não contam como tentativa e são ignoradas se a fila estiver
  ///   esgotada.
  Future<void> retryNow({bool manual = false}) async {
    if (manual && _exhausted) {
      _exhausted = false;
      for (final item in _pending) {
        item.attempts = 0;
      }
    }
    if (_exhausted) return;
    await _drain(countAttempt: manual);
  }

  Future<void> _drain({required bool countAttempt}) async {
    if (_retrying || _pending.isEmpty) return;
    _retrying = true;
    _cancelTimer();
    _publish();
    var networkFailed = false;
    try {
      if (!await _apiIsReachable()) {
        networkFailed = true;
        return;
      }
      while (_pending.isNotEmpty) {
        final request = _pending.first;
        if (request.sessionGeneration != _storage.identityGeneration) {
          _pending.removeFirst();
          if (request.persisted) await _store.delete(request.id);
          continue;
        }
        try {
          await request.operation(request.idempotencyKey);
          _pending.removeFirst();
          if (request.persisted) await _store.delete(request.id);
          _emit(
            OfflineQueueEvent(
              type: OfflineQueueEventType.delivered,
              resourceKey: request.resourceKey,
              description: request.description,
            ),
          );
        } on DioException catch (error) {
          if (isNetworkFailure(error)) {
            networkFailed = true;
            return;
          }
          await _reject(request, error);
        } catch (error) {
          await _reject(request, error);
        }
      }
    } finally {
      _retrying = false;
      if (networkFailed && _pending.isNotEmpty && countAttempt) {
        final head = _pending.first;
        head.attempts++;
        if (head.attempts >= maxAttempts) {
          _exhausted = true;
          _emit(
            OfflineQueueEvent(
              type: OfflineQueueEventType.exhausted,
              resourceKey: head.resourceKey,
              description: head.description,
            ),
          );
        }
      }
      if (_pending.isNotEmpty && !_exhausted) _scheduleRetry();
      _publish();
    }
  }

  Future<void> _reject(_PendingRequest<dynamic> request, Object error) async {
    _pending.removeFirst();
    if (request.persisted) await _store.delete(request.id);
    _emit(
      OfflineQueueEvent(
        type: OfflineQueueEventType.rejected,
        resourceKey: request.resourceKey,
        description: request.description,
        error: error,
      ),
    );
  }

  void clear() {
    _pending.clear();
    _exhausted = false;
    _cancelTimer();
    unawaited(_store.clear());
    _publish();
  }

  void dispose() {
    _pending.clear();
    _cancelTimer();
    unawaited(_events.close());
    status.dispose();
  }

  Future<bool> _apiIsReachable() async {
    try {
      await _dio.get<dynamic>(
        '/api/v1/',
        options: Options(validateStatus: (status) => status != null),
      );
      return true;
    } on DioException catch (error) {
      return !isNetworkFailure(error);
    }
  }

  void _scheduleRetry({bool immediate = false}) {
    if (_retryTimer != null) return;
    final delay = immediate ? const Duration(seconds: 2) : retryInterval;
    _nextRetryAt = DateTime.now().add(delay);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _nextRetryAt = null;
      unawaited(_drain(countAttempt: !immediate));
    });
  }

  void _cancelTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _nextRetryAt = null;
  }

  void _publish() {
    final head = _pending.isEmpty ? null : _pending.first;
    status.value = OfflineQueueStatus(
      pendingCount: _pending.length,
      attempts: head?.attempts ?? 0,
      maxAttempts: maxAttempts,
      nextRetryAt: _nextRetryAt,
      sending: _retrying,
      exhausted: _exhausted,
      description: head?.description ?? '',
    );
  }

  void _emit(OfflineQueueEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  String _newIdempotencyKey() =>
      'mobile-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
}

class _PendingRequest<T> {
  _PendingRequest({
    required this.id,
    required this.resourceKey,
    required this.description,
    required this.idempotencyKey,
    required this.sessionGeneration,
    required this.persisted,
    required this.operation,
  });

  final String id;
  final String resourceKey;
  final String description;
  final String idempotencyKey;
  final int sessionGeneration;
  final bool persisted;
  final OfflineOperation<T> operation;
  int attempts = 0;
}
