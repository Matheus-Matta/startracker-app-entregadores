import 'package:dio/dio.dart';

import '../../../core/network/api_collection.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/offline_request_queue.dart';
import '../../../core/network/paged_result.dart';
import '../../../core/presentation/delivery_terminology.dart';
import 'pickup_label_scope.dart';

/// Normaliza somente o que o contrato da retirada permite ao comparar no app.
///
/// Espacos internos fazem parte do codigo. A validacao definitiva continua
/// sendo feita pela API.
String normalizePickupCode(String code) => code.trim().toUpperCase();

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
    this.labelGranularity,
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
  final PickupLabelScope? labelGranularity;

  int get totalLabels =>
      orders.fold(0, (total, order) => total + order.totalLabels);

  int get scannedLabels =>
      orders.fold(0, (total, order) => total + order.scannedLabels);

  int get pendingLabels => totalLabels - scannedLabels;
}

class PickupCode {
  const PickupCode({required this.code, required this.scannedAt});

  final String code;
  final DateTime? scannedAt;

  bool get isScanned => scannedAt != null;
}

class PickupOrder {
  const PickupOrder({
    required this.orderId,
    required this.orderNumber,
    required this.customer,
    required this.codes,
    required this.pickedUpAt,
  });

  final int orderId;
  final String orderNumber;
  final String customer;
  final List<PickupCode> codes;
  final DateTime? pickedUpAt;

  bool get isPickedUp => pickedUpAt != null;

  int get totalLabels => codes.length;

  int get scannedLabels => codes.where((code) => code.isScanned).length;

  int get pendingLabels => totalLabels - scannedLabels;

  /// Localiza apenas codigos que vieram em `orders[].codes` da API.
  bool matchesCode(String scannedCode) {
    final key = normalizePickupCode(scannedCode);
    return codes.any((code) => normalizePickupCode(code.code) == key);
  }
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

class _WaveListSnapshot {
  const _WaveListSnapshot(this.createdAt, this.routes, this.waves);

  final DateTime createdAt;
  final List<Map<String, dynamic>> routes;
  final List<Map<String, dynamic>> waves;
}

class WaveService {
  WaveService(this.apiClient);
  final ApiClient apiClient;
  static const _listCacheDuration = Duration(seconds: 30);
  _WaveListSnapshot? _listCache;
  Future<_WaveListSnapshot>? _listOperation;
  int? _listOperationGeneration;
  int _listCacheGeneration = 0;

  Future<PagedResult<WaveListItem>> getWaves({
    required int page,
    String search = '',
    String status = '',
    bool refresh = false,
  }) async {
    const pageSize = 20;
    final snapshot = await _getListSnapshot(refresh: refresh);
    final routes = List<Map<String, dynamic>>.from(snapshot.routes);
    final waves = List<Map<String, dynamic>>.from(snapshot.waves);
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

  void invalidateCache() {
    _listCacheGeneration++;
    _listCache = null;
  }

  Future<_WaveListSnapshot> _getListSnapshot({required bool refresh}) async {
    final cached = _listCache;
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.createdAt) < _listCacheDuration) {
      return cached;
    }
    final ongoing = _listOperation;
    if (ongoing != null && _listOperationGeneration == _listCacheGeneration) {
      return ongoing;
    }
    final generation = _listCacheGeneration;
    final operation = _loadListSnapshot();
    _listOperation = operation;
    _listOperationGeneration = generation;
    try {
      final snapshot = await operation;
      if (generation == _listCacheGeneration) _listCache = snapshot;
      return snapshot;
    } finally {
      if (identical(_listOperation, operation)) {
        _listOperation = null;
        _listOperationGeneration = null;
      }
    }
  }

  Future<_WaveListSnapshot> _loadListSnapshot() async {
    final results = await Future.wait([
      _getAll('/api/v1/delivery/rotas/'),
      _getWavesAllowed(),
    ]);
    return _WaveListSnapshot(DateTime.now(), results[0], results[1]);
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
    final routeStatus = route?['status']?.toString() ?? '';
    final displayStatus = WaveService.displayStatus(waveStatus, routeStatus);
    final routeNumber = route?['route_number']?.toString() ?? '';
    return WaveListItem(
      waveId: waveId,
      routeId: routeId,
      routeNumber: routeId == null
          ? 'Aguardando retirada'
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

  static String displayStatus(String waveStatus, String routeStatus) {
    // A rota em andamento prevalece sobre um status defasado da wave. Isso
    // permite retomar o mapa mesmo quando uma transferencia adiciona uma nova
    // retirada pendente durante a execucao.
    if (routeStatus == 'started') return routeStatus;

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
    if (waveOwnedStatuses.contains(waveStatus) || routeStatus.isEmpty) {
      return waveStatus;
    }
    return routeStatus;
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
      status: WaveService.displayStatus(
        waveData['status']?.toString() ?? wave.status,
        route['status']?.toString() ?? '',
      ),
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
      return WaveService.parsePickupProgress(response.data, waveId);
    } on DioException catch (error) {
      if (error.response?.statusCode == 405) {
        return PickupProgress.disabled(waveId);
      }
      throw WaveServiceException(_errorMessage(error));
    }
  }

  Future<PickupProgress> registerPickup({
    required int waveId,
    required String code,
  }) async {
    final scannedCode = code.trim();
    if (scannedCode.isEmpty) {
      throw const WaveServiceException('Informe ou leia um código válido.');
    }
    try {
      final response = await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/waves/$waveId/retirada/',
        data: {'code': scannedCode},
      );
      invalidateCache();
      return WaveService.parsePickupProgress(response.data, waveId);
    } on DioException catch (error) {
      if (OfflineRequestQueue.isNetworkFailure(error)) {
        throw const WaveServiceException(
          'Sem conexão. A conferência da retirada precisa de internet.',
        );
      }
      throw WaveServiceException(_errorMessage(error));
    }
  }

  /// Marca um pedido da carga como "não vai".
  ///
  /// A API tira o pedido desta carga e desmembra o que ficou numa nota nova em
  /// `manual_assignment`, liberando a roteirização do restante.
  Future<PickupProgress> markOrderNotGoing({
    required int waveId,
    required int orderId,
  }) async {
    try {
      final response = await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/waves/$waveId/nao-vai/',
        data: {'order_id': orderId},
      );
      invalidateCache();
      final data = response.data;
      if (data is Map && data['orders'] is List) {
        return WaveService.parsePickupProgress(data, waveId);
      }
      return getPickupProgress(waveId);
    } on DioException catch (error) {
      if (OfflineRequestQueue.isNetworkFailure(error)) {
        throw const WaveServiceException(
          'Sem conexão. Marcar "não vai" precisa de internet para gerar a '
          'nova nota do pedido.',
        );
      }
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

  Future<OfflineMutationResult<WaveListItem>> optimizeAndRelease(
    WaveListItem wave,
  ) async {
    try {
      return await apiClient.offlineRequests.execute<WaveListItem>(
        resourceKey: 'wave:${wave.waveId}',
        description: 'Preparar rota da carga',
        operation: (key) => _optimizeAndReleaseRequest(wave, key),
      );
    } on WaveServiceException {
      rethrow;
    } on DioException catch (error) {
      throw WaveServiceException(_errorMessage(error));
    }
  }

  Future<WaveListItem> _optimizeAndReleaseRequest(
    WaveListItem wave,
    String idempotencyKey,
  ) async {
    try {
      try {
        await apiClient.dio.post<dynamic>(
          '/api/v1/delivery/waves/${wave.waveId}/prepare-route/',
          options: apiClient.offlineRequests.requestOptions(
            idempotencyKey,
            step: 'prepare',
          ),
        );
      } on DioException catch (error) {
        if (error.response?.statusCode != 404 &&
            error.response?.statusCode != 405) {
          rethrow;
        }
        // Compatibilidade temporária com o contrato administrativo anterior.
        await apiClient.dio.post<dynamic>(
          '/api/v1/delivery/waves/${wave.waveId}/optimize/',
          options: apiClient.offlineRequests.requestOptions(
            idempotencyKey,
            step: 'optimize',
          ),
        );
        await apiClient.dio.post<dynamic>(
          '/api/v1/delivery/waves/${wave.waveId}/release/',
          options: apiClient.offlineRequests.requestOptions(
            idempotencyKey,
            step: 'release',
          ),
        );
      }
      invalidateCache();
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
          'A roteirização terminou sem criar uma rota para esta carga.',
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
    } on DioException {
      rethrow;
    }
  }

  Future<OfflineMutationResult<void>> startRoute(int routeId) async {
    try {
      final result = await apiClient.offlineRequests.execute<void>(
        resourceKey: 'route:$routeId',
        description: 'Iniciar rota',
        operation: (key) async {
          await apiClient.dio.post<dynamic>(
            '/api/v1/delivery/rotas/$routeId/start/',
            options: apiClient.offlineRequests.requestOptions(key),
          );
        },
      );
      invalidateCache();
      return result;
    } on DioException catch (error) {
      throw WaveServiceException(_errorMessage(error));
    }
  }

  Future<List<Map<String, dynamic>>> _getAll(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => apiClient.getAllPages(path, queryParameters: queryParameters);

  String _errorMessage(DioException error) {
    final data = error.response?.data;
    if (data is Map) {
      for (final key in const [
        'detail',
        'non_field_errors',
        'code',
        'barcode',
        'label',
        'message',
        'error',
      ]) {
        final message = _firstApiError(data[key]);
        if (message != null) return useDeliveryTerminology(message);
      }
    }
    final message = _firstApiError(data);
    if (message != null) return useDeliveryTerminology(message);
    return 'Não foi possível concluir a operação. Tente novamente.';
  }

  static PickupProgress parsePickupProgress(dynamic raw, int fallbackWaveId) {
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    final rawOrders = data['orders'];
    final orders = <PickupOrder>[];
    if (rawOrders is List) {
      for (final rawOrder in rawOrders.whereType<Map>()) {
        final order = Map<String, dynamic>.from(rawOrder);
        final pickedUpAt = DateTime.tryParse(
          order['picked_up_at']?.toString() ?? '',
        );
        final codes = <PickupCode>[];
        final rawCodes = order['codes'];
        if (rawCodes is List) {
          for (final rawCode in rawCodes.whereType<Map>()) {
            final codeData = Map<String, dynamic>.from(rawCode);
            final code = codeData['code']?.toString().trim() ?? '';
            if (code.isEmpty) continue;
            codes.add(
              PickupCode(
                code: code,
                scannedAt: DateTime.tryParse(
                  codeData['scanned_at']?.toString() ?? '',
                ),
              ),
            );
          }
        }
        orders.add(
          PickupOrder(
            orderId: _asInt(order['order_id']) ?? 0,
            orderNumber: order['order_number']?.toString() ?? '',
            customer: order['customer']?.toString() ?? 'Cliente',
            codes: codes,
            pickedUpAt: pickedUpAt,
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
      pending:
          _asInt(data['pending']) ??
          orders.where((order) => !order.isPickedUp).length,
      isComplete: _asBool(data['is_complete']),
      orders: orders,
      labelGranularity: PickupLabelScope.tryFromConfiguration(data),
    );
  }

  int _compareNewest(DateTime? first, DateTime? second) {
    if (first == null && second == null) return 0;
    if (first == null) return 1;
    if (second == null) return -1;
    return second.compareTo(first);
  }

  static int? _asInt(dynamic value) => switch (value) {
    int number => number,
    String text => int.tryParse(text),
    _ => null,
  };

  static bool _asBool(dynamic value) => switch (value) {
    bool boolean => boolean,
    num number => number != 0,
    String text => const {'true', '1', 'yes'}.contains(text.toLowerCase()),
    _ => false,
  };
}

String? _firstApiError(dynamic value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  if (value is List) {
    for (final item in value) {
      final message = _firstApiError(item);
      if (message != null) return message;
    }
  }
  if (value is Map) {
    for (final item in value.values) {
      final message = _firstApiError(item);
      if (message != null) return message;
    }
  }
  return null;
}
