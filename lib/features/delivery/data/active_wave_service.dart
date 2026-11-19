import 'dart:async';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_collection.dart';
import '../../../core/network/offline_deadline.dart';
import '../../waves/data/active_route_service.dart';
import '../../waves/data/route_snapshot_store.dart';

class ActiveWave {
  const ActiveWave({
    required this.waveId,
    required this.routeId,
    required this.routeNumber,
    required this.status,
    required this.plannedDistanceMeters,
    required this.plannedDurationSeconds,
    required this.plannedStart,
  });

  final int waveId;
  final int routeId;
  final String routeNumber;
  final String status;
  final int plannedDistanceMeters;
  final int plannedDurationSeconds;
  final DateTime? plannedStart;
}

class ActiveWaveService {
  ActiveWaveService(
    this.apiClient, {
    this.activeRoutes,
    RouteSnapshotStore? store,
  }) : _store =
           store ?? RouteSnapshotStore(folder: 'active_wave', prefix: 'routes');

  /// Última lista de rotas ativas: reaberto sem sinal, o app ainda mostra a
  /// carga em andamento (antes a tela inicial dava erro de conexão).
  final RouteSnapshotStore _store;

  /// Fonte do status calculado no aparelho (ações ainda não enviadas).
  final ActiveRouteService? activeRoutes;

  static const _cacheDuration = Duration(seconds: 20);

  final ApiClient apiClient;
  ActiveWave? _cached;
  DateTime? _cachedAt;
  bool _hasCache = false;
  Future<ActiveWave?>? _operation;
  int _generation = 0;

  void invalidateCache() {
    _generation++;
    _hasCache = false;
    _cached = null;
    _cachedAt = null;
    _operation = null;
  }

  /// Carga ativa do entregador.
  ///
  /// Respostas recentes são reaproveitadas, consultas simultâneas são
  /// unificadas e, sem rede, a última carga conhecida continua disponível.
  Future<ActiveWave?> getActiveWave({bool refresh = false}) {
    final cachedAt = _cachedAt;
    if (!refresh &&
        _hasCache &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheDuration) {
      return Future.value(_cached);
    }
    final ongoing = _operation;
    if (ongoing != null) return ongoing;
    final generation = _generation;
    final operation = () async {
      try {
        final wave = await _loadActiveWave();
        if (generation == _generation) {
          _cached = wave;
          _cachedAt = DateTime.now();
          _hasCache = true;
        }
        return wave;
      } catch (error) {
        if (!isOfflineError(error)) rethrow;
        if (_hasCache) {
          final cached = _cached;
          // Rota fechada no aparelho deixa de ser a carga ativa, mesmo sem
          // o servidor ter confirmado ainda.
          if (cached != null && await _locallyFinished(cached.routeId)) {
            return null;
          }
          return cached;
        }
        final stored = await _store.read(0);
        final routes = stored?['routes'];
        if (routes is! List) rethrow;
        return _pick([
          for (final item in routes)
            if (item is Map) Map<String, dynamic>.from(item),
        ]);
      } finally {
        if (generation == _generation) _operation = null;
      }
    }();
    _operation = operation;
    return operation;
  }

  /// Logout: sem ação pendente, a carga do entregador não fica no aparelho.
  void clearSessionData({required bool keepOffline}) {
    invalidateCache();
    if (!keepOffline) unawaited(_store.clear());
  }

  Future<ActiveWave?> _loadActiveWave() async {
    final routes = await _getAllRoutes().timeout(OfflineDeadline.read);
    unawaited(_store.save(0, {'routes': routes}));
    return _pick(routes);
  }

  Future<ActiveWave?> _pick(List<Map<String, dynamic>> routes) async {
    const activeStatuses = {'released', 'accepted', 'started'};

    routes.sort((first, second) {
      final firstStarted = first['status']?.toString() == 'started';
      final secondStarted = second['status']?.toString() == 'started';
      if (firstStarted != secondStarted) return firstStarted ? -1 : 1;
      final firstDate = DateTime.tryParse(
        first['created_at']?.toString() ?? '',
      );
      final secondDate = DateTime.tryParse(
        second['created_at']?.toString() ?? '',
      );
      if (firstDate != null && secondDate != null) {
        final byDate = secondDate.compareTo(firstDate);
        if (byDate != 0) return byDate;
      } else if (firstDate == null && secondDate != null) {
        return 1;
      } else if (firstDate != null) {
        return -1;
      }
      return (_asInt(second['id']) ?? 0).compareTo(_asInt(first['id']) ?? 0);
    });

    for (final item in routes) {
      var status = item['status']?.toString() ?? '';
      final waveId = _asInt(item['wave']);
      final routeId = _asInt(item['id']);
      if (activeStatuses.contains(status) &&
          waveId != null &&
          routeId != null) {
        final local = await _localStatus(routeId);
        // Só a rota fechada no aparelho sai da tela. Uma cópia antiga ainda
        // "planejada" (salva antes da liberação) escondia a carga ativa.
        if (local != null && !_openRouteStatuses.contains(local)) continue;
        if (local == 'started') status = 'started';
        return ActiveWave(
          waveId: waveId,
          routeId: routeId,
          routeNumber: item['route_number']?.toString() ?? 'Rota ${item['id']}',
          status: status,
          plannedDistanceMeters: _asInt(item['planned_distance']) ?? 0,
          plannedDurationSeconds: _asInt(item['planned_duration']) ?? 0,
          plannedStart: DateTime.tryParse(
            item['planned_start']?.toString() ?? '',
          ),
        );
      }
    }
    return null;
  }

  Future<String?> _localStatus(int routeId) async {
    try {
      return (await activeRoutes?.storedRoute(routeId))?.status;
    } catch (_) {
      return null;
    }
  }

  static const _openRouteStatuses = {
    'planned',
    'released',
    'accepted',
    'started',
  };

  Future<bool> _locallyFinished(int routeId) async {
    final status = await _localStatus(routeId);
    return status != null && !_openRouteStatuses.contains(status);
  }

  Future<List<Map<String, dynamic>>> _getAllRoutes() async {
    // Só as rotas em andamento: antes vinha o histórico inteiro do entregador.
    return apiClient.getAllPages(
      '/api/v1/delivery/rotas/',
      queryParameters: const {
        'status': ['released', 'accepted', 'started'],
      },
    );
  }

  int? _asInt(dynamic value) => switch (value) {
    int number => number,
    String text => int.tryParse(text),
    _ => null,
  };
}
