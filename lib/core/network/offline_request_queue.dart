import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';

import '../storage/session_storage.dart';

enum OfflineQueueEventType { queued, delivered, rejected }

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

class OfflineMutationResult<T> {
  const OfflineMutationResult.completed(this.value) : queued = false;
  const OfflineMutationResult.queued() : value = null, queued = true;

  final T? value;
  final bool queued;
}

typedef OfflineOperation<T> = Future<T> Function(String idempotencyKey);

class OfflineRequestQueue {
  OfflineRequestQueue(
    this._dio,
    this._storage, {
    this.retryInterval = const Duration(seconds: 5),
  });

  final Dio _dio;
  final SessionStorage _storage;
  final Duration retryInterval;
  final Queue<_PendingRequest<dynamic>> _pending = Queue();
  final StreamController<OfflineQueueEvent> _events =
      StreamController<OfflineQueueEvent>.broadcast();

  Timer? _retryTimer;
  bool _retrying = false;
  int _sequence = 0;

  Stream<OfflineQueueEvent> get events => _events.stream;
  int get pendingCount => _pending.length;

  static bool isNetworkFailure(DioException error) {
    if (error.response != null || error.type == DioExceptionType.cancel) {
      return false;
    }
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return true;
    }
    return error.type == DioExceptionType.unknown &&
        (error.error is SocketException || error.error is TimeoutException);
  }

  Future<OfflineMutationResult<T>> execute<T>({
    required String resourceKey,
    required String description,
    required OfflineOperation<T> operation,
  }) async {
    final idempotencyKey = _newIdempotencyKey();
    try {
      return OfflineMutationResult<T>.completed(
        await operation(idempotencyKey),
      );
    } on DioException catch (error) {
      if (!isNetworkFailure(error)) rethrow;
      _pending.add(
        _PendingRequest<T>(
          resourceKey: resourceKey,
          description: description,
          idempotencyKey: idempotencyKey,
          sessionGeneration: _storage.sessionGeneration,
          operation: operation,
        ),
      );
      _emit(
        OfflineQueueEvent(
          type: OfflineQueueEventType.queued,
          resourceKey: resourceKey,
          description: description,
        ),
      );
      _startRetryTimer();
      return OfflineMutationResult<T>.queued();
    }
  }

  Options requestOptions(String idempotencyKey, {String? step}) => Options(
    headers: {
      'Idempotency-Key': step == null
          ? idempotencyKey
          : '$idempotencyKey-$step',
    },
  );

  Future<void> retryNow() async {
    if (_retrying || _pending.isEmpty) return;
    _retrying = true;
    try {
      if (!await _apiIsReachable()) return;
      while (_pending.isNotEmpty) {
        final request = _pending.first;
        if (request.sessionGeneration != _storage.sessionGeneration) {
          _pending.removeFirst();
          continue;
        }
        try {
          await request.operation(request.idempotencyKey);
          _pending.removeFirst();
          _emit(
            OfflineQueueEvent(
              type: OfflineQueueEventType.delivered,
              resourceKey: request.resourceKey,
              description: request.description,
            ),
          );
        } on DioException catch (error) {
          if (isNetworkFailure(error)) return;
          _pending.removeFirst();
          _emit(
            OfflineQueueEvent(
              type: OfflineQueueEventType.rejected,
              resourceKey: request.resourceKey,
              description: request.description,
              error: error,
            ),
          );
        } catch (error) {
          _pending.removeFirst();
          _emit(
            OfflineQueueEvent(
              type: OfflineQueueEventType.rejected,
              resourceKey: request.resourceKey,
              description: request.description,
              error: error,
            ),
          );
        }
      }
    } finally {
      _retrying = false;
      if (_pending.isEmpty) _stopRetryTimer();
    }
  }

  void clear() {
    _pending.clear();
    _stopRetryTimer();
  }

  void dispose() {
    clear();
    unawaited(_events.close());
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

  void _startRetryTimer() {
    _retryTimer ??= Timer.periodic(retryInterval, (_) => unawaited(retryNow()));
  }

  void _stopRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _emit(OfflineQueueEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  String _newIdempotencyKey() =>
      'mobile-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
}

class _PendingRequest<T> {
  const _PendingRequest({
    required this.resourceKey,
    required this.description,
    required this.idempotencyKey,
    required this.sessionGeneration,
    required this.operation,
  });

  final String resourceKey;
  final String description;
  final String idempotencyKey;
  final int sessionGeneration;
  final OfflineOperation<T> operation;
}
