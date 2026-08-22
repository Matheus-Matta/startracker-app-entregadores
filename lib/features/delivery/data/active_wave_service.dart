import '../../../core/network/api_client.dart';

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
  const ActiveWaveService(this.apiClient);

  final ApiClient apiClient;

  Future<ActiveWave?> getActiveWave() async {
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
    final routes = <Map<String, dynamic>>[];
    var page = 1;
    while (page <= 100) {
      final response = await apiClient.dio.get<dynamic>(
        '/api/v1/delivery/rotas/',
        queryParameters: {'page': page},
      );
      routes.addAll(_itemsFrom(response.data));
      final data = response.data;
      if (data is! Map || data['next'] == null) break;
      page++;
    }
    return routes;
  }

  List<Map<String, dynamic>> _itemsFrom(dynamic data) {
    final rawItems = data is Map ? data['results'] : data;
    if (rawItems is! List) return const [];
    return rawItems
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  int? _asInt(dynamic value) => switch (value) {
    int number => number,
    String text => int.tryParse(text),
    _ => null,
  };
}
