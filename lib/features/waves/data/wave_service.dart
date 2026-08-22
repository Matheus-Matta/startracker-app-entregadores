import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/paged_result.dart';

class WaveListItem {
  const WaveListItem({
    required this.waveId,
    required this.routeId,
    required this.routeNumber,
    required this.status,
    required this.plannedDistanceMeters,
    required this.plannedStart,
    required this.createdAt,
  });

  final int waveId;
  final int? routeId;
  final String routeNumber;
  final String status;
  final int plannedDistanceMeters;
  final DateTime? plannedStart;
  final DateTime? createdAt;

  WaveListItem withRoute({
    required int id,
    required String number,
    required String routeStatus,
    required int distanceMeters,
    required DateTime? start,
    required DateTime? routeCreatedAt,
  }) => WaveListItem(
    waveId: waveId,
    routeId: id,
    routeNumber: number,
    status: routeStatus,
    plannedDistanceMeters: distanceMeters,
    plannedStart: start,
    createdAt: routeCreatedAt ?? createdAt,
  );
}

class WaveDetails {
  const WaveDetails({
    required this.waveId,
    required this.routeId,
    required this.routeNumber,
    required this.status,
    required this.plannedDistanceMeters,
    required this.plannedDurationSeconds,
    required this.plannedStart,
    required this.plannedEnd,
    required this.orders,
    required this.pickup,
  });

  final int waveId;
  final int? routeId;
  final String routeNumber;
  final String status;
  final int plannedDistanceMeters;
  final int plannedDurationSeconds;
  final DateTime? plannedStart;
  final DateTime? plannedEnd;
  final List<WaveOrderItem> orders;
  final PickupProgress pickup;
}

class PickupProgress {
  const PickupProgress({
    required this.waveId,
    required this.enabled,
    required this.barcodeSource,
    required this.total,
    required this.pickedUp,
    required this.pending,
    required this.isComplete,
    required this.orders,
  });

  factory PickupProgress.disabled(int waveId) => PickupProgress(
    waveId: waveId,
    enabled: false,
    barcodeSource: 'order_number',
    total: 0,
    pickedUp: 0,
    pending: 0,
    isComplete: true,
    orders: const [],
  );

  final int waveId;
  final bool enabled;
  final String barcodeSource;
  final int total;
  final int pickedUp;
  final int pending;
  final bool isComplete;
  final List<PickupOrder> orders;
}

class PickupOrder {
  const PickupOrder({
    required this.orderId,
    required this.orderNumber,
    required this.customer,
    required this.code,
    required this.pickedUpAt,
  });

  final int orderId;
  final String orderNumber;
  final String customer;
  final String code;
  final DateTime? pickedUpAt;

  bool get isPickedUp => pickedUpAt != null;
}

class WaveOrderItem {
  const WaveOrderItem({
    required this.stopId,
    required this.sequence,
    required this.stopStatus,
    required this.plannedEta,
    required this.orderId,
    required this.orderNumber,
    required this.customerName,
    required this.address,
    required this.city,
    required this.state,
    required this.units,
    required this.weightGrams,
  });

  final int stopId;
  final int sequence;
  final String stopStatus;
  final DateTime? plannedEta;
  final int orderId;
  final String orderNumber;
  final String customerName;
  final String address;
  final String city;
  final String state;
  final int units;
  final int weightGrams;
}

class WaveServiceException implements Exception {
  const WaveServiceException(this.message);

  final String message;
}

class WaveService {
  const WaveService(this.apiClient);
  final ApiClient apiClient;

  Future<PagedResult<WaveListItem>> getWaves({
    required int page,
    String search = '',
    String status = '',
  }) async {
    const pageSize = 20;
    final routes = await _getAll('/api/v1/delivery/rotas/');
    final waves = await _getWavesAllowed();
    final query = search.trim().toLowerCase();
    final items = <WaveListItem>[];

    routes.sort((first, second) {
      final firstDate = DateTime.tryParse(
        first['created_at']?.toString() ?? '',
      );
      final secondDate = DateTime.tryParse(
        second['created_at']?.toString() ?? '',
      );
      final byDate = _compareNewest(firstDate, secondDate);
      if (byDate != 0) return byDate;
      return (_asInt(second['id']) ?? 0).compareTo(_asInt(first['id']) ?? 0);
    });

    final routesByWave = <int, Map<String, dynamic>>{};
    for (final route in routes) {
      final waveId = _asInt(route['wave']);
      if (waveId != null) routesByWave.putIfAbsent(waveId, () => route);
    }

    if (waves.isNotEmpty) {
      waves.sort((first, second) {
        final firstDate = _waveDate(first);
        final secondDate = _waveDate(second);
        final byDate = _compareNewest(firstDate, secondDate);
        if (byDate != 0) return byDate;
        return (_asInt(second['id']) ?? 0).compareTo(_asInt(first['id']) ?? 0);
      });
      for (final wave in waves) {
        final waveId = _asInt(wave['id']);
        if (waveId == null) continue;
        final route = routesByWave[waveId];
        final item = _waveItem(waveId, wave, route);
        if (_matches(item, query, status)) items.add(item);
      }
    } else {
      // Compatibilidade enquanto a API do entregador ainda não expõe waves.
      for (final route in routes) {
        final waveId = _asInt(route['wave']);
        final routeId = _asInt(route['id']);
        if (waveId == null || routeId == null) continue;
        final item = _routeItem(waveId, routeId, route);
        if (!items.any((current) => current.waveId == waveId) &&
            _matches(item, query, status)) {
          items.add(item);
        }
      }
    }

    final start = (page - 1) * pageSize;
    final pageItems = start >= items.length
        ? const <WaveListItem>[]
        : items.sublist(
            start,
            start + pageSize < items.length ? start + pageSize : items.length,
          );

    return PagedResult(
      items: pageItems,
      count: items.length,
      page: page,
      hasNext: start + pageSize < items.length,
      hasPrevious: page > 1,
    );
  }

  Future<List<Map<String, dynamic>>> _getWavesAllowed() async {
    try {
      return await _getAll('/api/v1/delivery/waves/');
    } on DioException catch (error) {
      if (error.response?.statusCode == 403 ||
          error.response?.statusCode == 404) {
        return const [];
      }
      rethrow;
    }
  }

  WaveListItem _waveItem(
    int waveId,
    Map<String, dynamic> wave,
    Map<String, dynamic>? route,
  ) {
    final routeId = _asInt(route?['id']);
    final waveStatus = wave['status']?.toString() ?? '';
    final routeStatus = route?['status']?.toString();
    const waveOwnedStatuses = {
      'collecting',
      'ready',
      'optimizing',
      'failed',
      'closed',
      'cancelled',
      'completed',
      'partially_completed',
    };
    final displayStatus = waveOwnedStatuses.contains(waveStatus)
        ? waveStatus
        : routeStatus ?? waveStatus;
    final routeNumber = route?['route_number']?.toString() ?? '';
    return WaveListItem(
      waveId: waveId,
      routeId: routeId,
      routeNumber: routeId == null
          ? 'Aguardando roteirização'
          : routeNumber.isEmpty
          ? 'Rota #$routeId'
          : routeNumber,
      status: displayStatus,
      plannedDistanceMeters: _asInt(route?['planned_distance']) ?? 0,
      plannedStart: DateTime.tryParse(
        route?['planned_start']?.toString() ?? '',
      ),
      createdAt: _waveDate(wave),
    );
  }

  WaveListItem _routeItem(int waveId, int routeId, Map<String, dynamic> route) {
    final number = route['route_number']?.toString() ?? '';
    return WaveListItem(
      waveId: waveId,
      routeId: routeId,
      routeNumber: number.isEmpty ? 'Rota #$routeId' : number,
      status: route['status']?.toString() ?? '',
      plannedDistanceMeters: _asInt(route['planned_distance']) ?? 0,
      plannedStart: DateTime.tryParse(route['planned_start']?.toString() ?? ''),
      createdAt: DateTime.tryParse(route['created_at']?.toString() ?? ''),
    );
  }

  bool _matches(WaveListItem item, String query, String status) {
    if (status.isNotEmpty && item.status != status) return false;
    return query.isEmpty ||
        item.routeNumber.toLowerCase().contains(query) ||
        item.waveId.toString().contains(query);
  }

  DateTime? _waveDate(Map<String, dynamic> wave) => DateTime.tryParse(
    (wave['created_at'] ?? wave['opened_at'])?.toString() ?? '',
  );

  Future<WaveDetails> getWaveDetails(WaveListItem wave) async {
    final routeId = wave.routeId;
    final pickup = await getPickupProgress(wave.waveId);
    final waveData = await _getOptionalMap(
      '/api/v1/delivery/waves/${wave.waveId}/',
    );
    final route = routeId == null
        ? const <String, dynamic>{}
        : await _getOptionalMap('/api/v1/delivery/rotas/$routeId/');
    final stops = routeId == null
        ? const <Map<String, dynamic>>[]
        : await _getAll(
            '/api/v1/delivery/paradas/',
            queryParameters: {'route': routeId},
          );
    final routeStops = stops
        .where((item) => _asInt(item['route']) == routeId)
        .toList();

    // WaveOrder existe desde a criação da wave, antes das RouteStops.
    final links = await _getAllOptional(
      '/api/v1/delivery/pedidos-wave/',
      queryParameters: {'wave': wave.waveId},
    );
    final waveLinks =
        links.where((item) => _relationId(item['wave']) == wave.waveId).toList()
          ..sort((first, second) {
            final firstDate = DateTime.tryParse(
              first['added_at']?.toString() ?? '',
            );
            final secondDate = DateTime.tryParse(
              second['added_at']?.toString() ?? '',
            );
            if (firstDate != null && secondDate != null) {
              final byDate = firstDate.compareTo(secondDate);
              if (byDate != 0) return byDate;
            }
            return (_asInt(first['id']) ?? 0).compareTo(
              _asInt(second['id']) ?? 0,
            );
          });

    final orders = await _getAll(
      '/api/v1/delivery/pedidos/',
      queryParameters: {'wave': wave.waveId},
    );
    final ordersById = <int, Map<String, dynamic>>{};
    for (final order in orders) {
      final id = _asInt(order['id']);
      if (id != null) ordersById[id] = order;
    }

    // Aceita também endpoints que devolvam os pedidos aninhados na wave/link.
    for (final raw in [waveData['orders'], waveData['wave_orders']]) {
      if (raw is! List) continue;
      for (final value in raw) {
        final item = value is Map
            ? Map<String, dynamic>.from(value)
            : const <String, dynamic>{};
        final nested = item['order'] is Map
            ? Map<String, dynamic>.from(item['order'] as Map)
            : item;
        final id = _asInt(nested['id']) ?? _relationId(item['order']);
        if (id != null && nested.length > 1) ordersById[id] = nested;
      }
    }
    for (final link in waveLinks) {
      if (link['order'] is! Map) continue;
      final nested = Map<String, dynamic>.from(link['order'] as Map);
      final id = _asInt(nested['id']);
      if (id != null) ordersById[id] = nested;
    }

    final stopsByOrder = <int, Map<String, dynamic>>{
      for (final stop in routeStops)
        if (_relationId(stop['order']) case final int orderId) orderId: stop,
    };
    final orderedIds = <int>[];
    void addOrderId(int? id) {
      if (id != null && !orderedIds.contains(id)) orderedIds.add(id);
    }

    final sortedStops = List<Map<String, dynamic>>.from(routeStops)
      ..sort(
        (first, second) => (_asInt(first['sequence']) ?? 0).compareTo(
          _asInt(second['sequence']) ?? 0,
        ),
      );
    for (final stop in sortedStops) {
      addOrderId(_relationId(stop['order']));
    }
    for (final link in waveLinks) {
      addOrderId(_relationId(link['order']));
    }
    for (final raw in [waveData['orders'], waveData['wave_orders']]) {
      if (raw is! List) continue;
      for (final value in raw) {
        addOrderId(
          value is Map
              ? _relationId(value['order'] ?? value)
              : _relationId(value),
        );
      }
    }
    for (final order in orders) {
      final linkedWave = _relationId(
        order['wave'] ?? order['wave_id'] ?? order['delivery_wave'],
      );
      if (linkedWave == wave.waveId) addOrderId(_asInt(order['id']));
    }

    final waveOrders = <WaveOrderItem>[];
    for (var index = 0; index < orderedIds.length; index++) {
      final orderId = orderedIds[index];
      final order = ordersById[orderId] ?? const <String, dynamic>{};
      final stop = stopsByOrder[orderId];
      final addressParts = [
        order['address']?.toString() ?? '',
        order['address_number']?.toString() ?? '',
      ].where((part) => part.trim().isNotEmpty);
      waveOrders.add(
        WaveOrderItem(
          stopId: _asInt(stop?['id']) ?? 0,
          sequence: _asInt(stop?['sequence']) ?? index + 1,
          stopStatus:
              stop?['status']?.toString() ??
              order['status']?.toString() ??
              'planned',
          plannedEta: DateTime.tryParse(stop?['planned_eta']?.toString() ?? ''),
          orderId: orderId,
          orderNumber: order['order_number']?.toString() ?? '#$orderId',
          customerName: order['customer_name']?.toString() ?? 'Cliente',
          address: addressParts.join(', '),
          city: order['city']?.toString() ?? '',
          state: order['state']?.toString() ?? '',
          units: _asInt(order['units']) ?? 0,
          weightGrams: _asInt(order['weight']) ?? 0,
        ),
      );
    }
    waveOrders.sort((a, b) => a.sequence.compareTo(b.sequence));

    return WaveDetails(
      waveId: _asInt(route['wave']) ?? wave.waveId,
      routeId: _asInt(route['id']) ?? wave.routeId,
      routeNumber: route['route_number']?.toString() ?? wave.routeNumber,
      status:
          waveData['status']?.toString() ??
          route['status']?.toString() ??
          wave.status,
      plannedDistanceMeters:
          _asInt(route['planned_distance']) ?? wave.plannedDistanceMeters,
      plannedDurationSeconds: _asInt(route['planned_duration']) ?? 0,
      plannedStart:
          DateTime.tryParse(route['planned_start']?.toString() ?? '') ??
          wave.plannedStart,
      plannedEnd: DateTime.tryParse(route['planned_end']?.toString() ?? ''),
      orders: waveOrders,
      pickup: pickup,
    );
  }

  Future<PickupProgress> getPickupProgress(int waveId) async {
    try {
      final response = await apiClient.dio.get<dynamic>(
        '/api/v1/delivery/waves/$waveId/retirada/',
      );
      return _pickupProgress(response.data, waveId);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404 ||
          error.response?.statusCode == 405) {
        return PickupProgress.disabled(waveId);
      }
      throw WaveServiceException(_errorMessage(error));
    }
  }

  Future<PickupProgress> registerPickup({
    required int waveId,
    required String code,
  }) async {
    try {
      final response = await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/waves/$waveId/retirada/',
        data: {'code': code.trim()},
      );
      return _pickupProgress(response.data, waveId);
    } on DioException catch (error) {
      throw WaveServiceException(_errorMessage(error));
    }
  }

  Future<Map<String, dynamic>> _getOptionalMap(String path) async {
    try {
      final response = await apiClient.dio.get<dynamic>(path);
      return response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : const {};
    } on DioException catch (error) {
      if (error.response?.statusCode == 403 ||
          error.response?.statusCode == 404) {
        return const {};
      }
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> _getAllOptional(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      return await _getAll(path, queryParameters: queryParameters);
    } on DioException catch (error) {
      if (error.response?.statusCode == 403 ||
          error.response?.statusCode == 404) {
        return const [];
      }
      rethrow;
    }
  }

  int? _relationId(dynamic value) {
    if (value is Map) return _asInt(value['id']);
    return _asInt(value);
  }

  Future<WaveListItem> optimizeAndRelease(WaveListItem wave) async {
    try {
      try {
        await apiClient.dio.post<dynamic>(
          '/api/v1/delivery/waves/${wave.waveId}/prepare-route/',
        );
      } on DioException catch (error) {
        if (error.response?.statusCode != 404 &&
            error.response?.statusCode != 405) {
          rethrow;
        }
        // Compatibilidade temporária com o contrato administrativo anterior.
        await apiClient.dio.post<dynamic>(
          '/api/v1/delivery/waves/${wave.waveId}/optimize/',
        );
        await apiClient.dio.post<dynamic>(
          '/api/v1/delivery/waves/${wave.waveId}/release/',
        );
      }
      final routes = await _getAll('/api/v1/delivery/rotas/');
      final matching =
          routes.where((route) => _asInt(route['wave']) == wave.waveId).toList()
            ..sort(
              (first, second) => (_asInt(second['id']) ?? 0).compareTo(
                _asInt(first['id']) ?? 0,
              ),
            );
      if (matching.isEmpty) {
        throw const WaveServiceException(
          'A roteirização terminou sem criar uma rota para esta wave.',
        );
      }
      final route = matching.first;
      final routeId = _asInt(route['id'])!;
      final number = route['route_number']?.toString() ?? '';
      return wave.withRoute(
        id: routeId,
        number: number.isEmpty ? 'Rota #$routeId' : number,
        routeStatus: route['status']?.toString() ?? 'released',
        distanceMeters: _asInt(route['planned_distance']) ?? 0,
        start: DateTime.tryParse(route['planned_start']?.toString() ?? ''),
        routeCreatedAt: DateTime.tryParse(
          route['created_at']?.toString() ?? '',
        ),
      );
    } on WaveServiceException {
      rethrow;
    } on DioException catch (error) {
      throw WaveServiceException(_errorMessage(error));
    }
  }

  Future<void> startRoute(int routeId) async {
    try {
      await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/rotas/$routeId/start/',
      );
    } on DioException catch (error) {
      throw WaveServiceException(_errorMessage(error));
    }
  }

  Future<List<Map<String, dynamic>>> _getAll(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final items = <Map<String, dynamic>>[];
    var page = 1;

    while (page <= 100) {
      final response = await apiClient.dio.get<dynamic>(
        path,
        queryParameters: {...?queryParameters, 'page': page},
      );
      final data = response.data;
      final rawItems = data is Map ? data['results'] : data;
      if (rawItems is List) {
        items.addAll(
          rawItems.whereType<Map>().map(
            (item) => Map<String, dynamic>.from(item),
          ),
        );
      }
      if (data is! Map || data['next'] == null) break;
      page++;
    }
    return items;
  }

  String _errorMessage(DioException error) {
    final data = error.response?.data;
    if (data is List && data.isNotEmpty) return data.first.toString();
    if (data is Map) {
      final detail = data['detail'] ?? data['non_field_errors'];
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) return detail.first.toString();
    }
    return 'Não foi possível concluir a operação. Tente novamente.';
  }

  PickupProgress _pickupProgress(dynamic raw, int fallbackWaveId) {
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    final rawOrders = data['orders'];
    final orders = <PickupOrder>[];
    if (rawOrders is List) {
      for (final rawOrder in rawOrders.whereType<Map>()) {
        final order = Map<String, dynamic>.from(rawOrder);
        orders.add(
          PickupOrder(
            orderId: _asInt(order['order_id']) ?? 0,
            orderNumber: order['order_number']?.toString() ?? '',
            customer: order['customer']?.toString() ?? 'Cliente',
            code: order['code']?.toString() ?? '',
            pickedUpAt: DateTime.tryParse(
              order['picked_up_at']?.toString() ?? '',
            ),
          ),
        );
      }
    }
    return PickupProgress(
      waveId: _asInt(data['wave_id']) ?? fallbackWaveId,
      enabled: _asBool(data['pickup_enabled']),
      barcodeSource: data['barcode_source']?.toString() ?? 'order_number',
      total: _asInt(data['total']) ?? orders.length,
      pickedUp:
          _asInt(data['picked_up']) ??
          orders.where((order) => order.isPickedUp).length,
      pending: _asInt(data['pending']) ?? 0,
      isComplete: _asBool(data['is_complete']),
      orders: orders,
    );
  }

  int _compareNewest(DateTime? first, DateTime? second) {
    if (first == null && second == null) return 0;
    if (first == null) return 1;
    if (second == null) return -1;
    return second.compareTo(first);
  }

  int? _asInt(dynamic value) => switch (value) {
    int number => number,
    String text => int.tryParse(text),
    _ => null,
  };

  bool _asBool(dynamic value) => switch (value) {
    bool boolean => boolean,
    num number => number != 0,
    String text => const {'true', '1', 'yes'}.contains(text.toLowerCase()),
    _ => false,
  };
}
