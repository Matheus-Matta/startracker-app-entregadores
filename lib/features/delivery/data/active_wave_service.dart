import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_collection.dart';
import '../../../core/network/offline_request_queue.dart';

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
  ActiveWaveService(this.apiClient);

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
      } on DioException catch (error) {
        if (_hasCache && OfflineRequestQueue.isNetworkFailure(error)) {
          return _cached;
        }
        rethrow;
      } finally {
        if (generation == _generation) _operation = null;
      }
    }();
    _operation = operation;
    return operation;
  }

  Future<ActiveWave?> _loadActiveWave() async {
    final routes = await _getAllRoutes();
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
      final status = item['status']?.toString() ?? '';
      final waveId = _asInt(item['wave']);
      final routeId = _asInt(item['id']);
      if (activeStatuses.contains(status) &&
          waveId != null &&
          routeId != null) {
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

  Future<List<Map<String, dynamic>>> _getAllRoutes() async {
    return apiClient.getAllPages('/api/v1/delivery/rotas/');
  }

  int? _asInt(dynamic value) => switch (value) {
    int number => number,
    String text => int.tryParse(text),
    _ => null,
  };
}
