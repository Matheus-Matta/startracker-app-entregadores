import 'dart:async';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../network/api_client.dart';
import '../network/offline_request_queue.dart';
import 'mobile_sync.dart';

/// Conta ao servidor o que o aparelho ainda não conseguiu enviar.
///
/// O portal (Entregas › Sincronização do app) mostra quem tem ação parada ou
/// recusada; sem isso o problema só era visto pelo entregador. Informar é
/// "melhor esforço": sem sinal não informa, e nada disso entra na fila nem
/// no histórico de falhas.
class SyncStatusReporter {
  SyncStatusReporter(
    this.apiClient, {
    this.minInterval = const Duration(minutes: 1),
    this.heartbeat = const Duration(minutes: 10),
    this.debounce = const Duration(seconds: 3),
    Future<String> Function()? appVersion,
  }) : _appVersion = appVersion ?? _platformVersion;

  static const endpoint = '${MobileSync.endpoint}situacao/';
  static const _maxRejected = 10;

  final ApiClient apiClient;
  final Duration minInterval;
  final Duration heartbeat;
  final Duration debounce;
  final Future<String> Function() _appVersion;

  OfflineRequestQueue get _queue => apiClient.offlineRequests;

  Timer? _debounceTimer;
  Timer? _heartbeatTimer;
  StreamSubscription<OfflineQueueEvent>? _events;
  String? _lastSent;
  DateTime? _lastSentAt;
  DateTime? _lastDeliveredAt;
  bool _sending = false;
  bool _changedWhileSending = false;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _queue.status.addListener(_onStatus);
    _events = _queue.events.listen((event) {
      if (event.type == OfflineQueueEventType.delivered) {
        _lastDeliveredAt = DateTime.now();
      }
    });
    _heartbeatTimer = Timer.periodic(heartbeat, (_) {
      // Com pendência, um sinal periódico mostra que o aparelho está vivo
      // (ou, pela falta dele, que está sem sinal há muito tempo).
      // Também quando o último aviso não chegou: um "fila vazia" perdido
      // deixava o portal mostrando ação parada que já tinha sido enviada.
      final signature = _signature();
      if (signature != '0:0' || (_lastSent != null && _lastSent != signature)) {
        unawaited(report(force: true));
      }
    });
    _onStatus();
  }

  void stop() {
    _queue.status.removeListener(_onStatus);
    unawaited(_events?.cancel());
    _debounceTimer?.cancel();
    _heartbeatTimer?.cancel();
    _started = false;
  }

  /// Troca de sessão: o próximo entregador começa do zero.
  void resetSession() {
    _lastSent = null;
    _lastSentAt = null;
    _lastDeliveredAt = null;
  }

  String _signature() {
    final status = _queue.status.value;
    return '${status.pendingCount}:${status.rejectedCount}';
  }

  void _onStatus() {
    final signature = _signature();
    if (signature == _lastSent) return;
    // Nunca houve nada a informar: não gera requisição à toa.
    if (_lastSent == null && signature == '0:0') return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(report()));
  }

  /// Envia a situação atual. Devolve `true` se o servidor recebeu.
  Future<bool> report({bool force = false}) async {
    if (_sending) {
      // Mudou durante um envio: manda de novo ao terminar, em vez de perder
      // (o "fila vazia" ficava para o próximo sinal, 10 min depois).
      _changedWhileSending = true;
      return false;
    }
    final signature = _signature();
    final cleared = signature == '0:0';
    final lastAt = _lastSentAt;
    if (!force &&
        !cleared &&
        lastAt != null &&
        DateTime.now().difference(lastAt) < minInterval) {
      // Muitas mudanças seguidas (lote enviando): informa no fim.
      _debounceTimer?.cancel();
      _debounceTimer = Timer(
        minInterval - DateTime.now().difference(lastAt),
        () => unawaited(report()),
      );
      return false;
    }
    _sending = true;
    try {
      final pending = _queue.pendingRequests;
      final rejected = _queue.rejectedRequests;
      final oldest = pending.isEmpty
          ? null
          : pending
                .map((item) => item.createdAt)
                .reduce((a, b) => a.isBefore(b) ? a : b);
      await apiClient.dio.post<dynamic>(
        endpoint,
        data: {
          'pending_count': pending.length,
          'rejected_count': rejected.length,
          'oldest_pending_at': oldest?.toUtc().toIso8601String(),
          'last_delivered_at': _lastDeliveredAt?.toUtc().toIso8601String(),
          'app_version': await _appVersion(),
          'rejected': [
            for (final item in rejected.take(_maxRejected))
              {
                'description': item.description,
                'reason': item.rejection ?? '',
                'created_at': item.createdAt.toUtc().toIso8601String(),
              },
          ],
        },
        options: Options(
          extra: const {
            ApiClient.noFailureLog: true,
            ApiClient.noReadRetry: true,
          },
        ),
      );
      _lastSent = signature;
      _lastSentAt = DateTime.now();
      return true;
    } catch (_) {
      // Sem sinal/servidor antigo: tenta de novo na próxima mudança ou sinal.
      return false;
    } finally {
      _sending = false;
      if (_changedWhileSending) {
        _changedWhileSending = false;
        if (_started && _signature() != _lastSent) _onStatus();
      }
    }
  }

  static Future<String> _platformVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return '';
    }
  }
}
