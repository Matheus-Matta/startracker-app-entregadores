import 'dart:async';

import 'package:dio/dio.dart';

import '../../../core/network/api_collection.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/offline_deadline.dart';
import '../../../core/network/offline_request_queue.dart';
import '../../../core/network/paged_result.dart';
import '../../../core/presentation/delivery_terminology.dart';
import '../../../core/sync/mobile_sync.dart';
import 'active_route_service.dart';
import 'local_pickup_state.dart';
import 'local_route_state.dart';
import 'pickup_label_scope.dart';
import 'route_snapshot_store.dart';

/// Normaliza a etiqueta como o servidor compara (`pickup._match`): sem
/// diferenciar caixa e sem espaço nenhum. Com a conferência feita sem rede,
/// o app precisa aceitar e recusar exatamente o que a API aceita e recusa.
String normalizePickupCode(String code) => pickupMatchKey(code);

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

  WaveOrderItem withStopStatus(String status) => WaveOrderItem(
    stopId: stopId,
    sequence: sequence,
    stopStatus: status,
    plannedEta: plannedEta,
    orderId: orderId,
    orderNumber: orderNumber,
    customerName: customerName,
    address: address,
    city: city,
    state: state,
    units: units,
    weightGrams: weightGrams,
  );
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
  WaveService(
    this.apiClient, {
    MobileSync? sync,
    RouteSnapshotStore? pickupStore,
    RouteSnapshotStore? listStore,
  }) : sync = sync ?? MobileSync(apiClient),
       _pickupStore = pickupStore ?? RouteSnapshotStore.pickup(),
       _listStore =
           listStore ??
           RouteSnapshotStore(folder: 'wave_list', prefix: 'list') {
    apiClient.offlineRequests.registerRestoreHandler(_prepareRouteType, (
      key,
      payload,
      _,
    ) async {
      final waveId = _asInt(payload['wave_id']);
      if (waveId == null) return null;
      await _postPrepareRoute(waveId, key);
      invalidateCache();
      return null;
    });
    _syncSubscription = this.sync.applied.listen(
      (applied) => unawaited(_onSyncApplied(applied)),
    );
  }

  final MobileSync sync;
  final RouteSnapshotStore _pickupStore;
  final RouteSnapshotStore _listStore;
  // Mantida viva durante todo o app (o serviço é um singleton).
  // ignore: unused_field
  late final StreamSubscription<SyncApplied> _syncSubscription;

  /// Status calculado no aparelho para a lista (definido pelo app).
  ActiveRouteService? activeRoutes;

  /// Última conferência lida do servidor, por carga.
  final Map<int, Map<String, dynamic>> _pickupRaw = {};

  /// Rotas já baixadas nesta sessão por `_prefetchReadyRoutes`.
  final Set<int> _prefetchedRoutes = {};

  static const _prepareRouteType = 'wave.prepare_route';
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
        if (_matches(item, query, '')) items.add(item);
      }
    } else {
      // Compatibilidade enquanto a API do entregador ainda não expõe waves.
      for (final route in routes) {
        final waveId = _asInt(route['wave']);
        final routeId = _asInt(route['id']);
        if (waveId == null || routeId == null) continue;
        final item = _routeItem(waveId, routeId, route);
        if (!items.any((current) => current.waveId == waveId) &&
            _matches(item, query, '')) {
          items.add(item);
        }
      }
    }

    // Ler a cópia de cada rota do disco custa caro (centenas de ms com o
    // histórico inteiro); só vale para cargas da página atual e quando há
    // ação do aparelho que o servidor ainda pode não refletir.
    final hasLocal = sync.localEvents().isNotEmpty;
    final firstIndex = (page - 1) * pageSize;
    for (var index = 0; index < items.length; index++) {
      final onPage = index >= firstIndex && index < firstIndex + pageSize;
      if (hasLocal && (onPage || status.isNotEmpty)) {
        items[index] = await _withLocalStatus(items[index]);
      }
    }
    if (status.isNotEmpty) {
      items.removeWhere((item) => item.status != status);
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

  /// Logout/troca de conta.
  void clearSessionData({required bool keepOffline}) {
    invalidateCache();
    _pickupRaw.clear();
    _prefetchedRoutes.clear();
    if (!keepOffline) {
      unawaited(_pickupStore.clear());
      unawaited(_listStore.clear());
    }
  }

  /// Status da carga com o que foi feito no aparelho e ainda não chegou ao
  /// servidor (rota iniciada, concluída), pela mesma regra do servidor.
  Future<WaveListItem> _withLocalStatus(WaveListItem item) async {
    final routeId = item.routeId;
    if (routeId == null || activeRoutes == null) return item;
    ActiveRoute? route;
    try {
      route = await activeRoutes!.storedRoute(routeId);
    } catch (_) {}
    if (route == null) return item;
    final status = WaveService.displayStatus(
      route.waveStatus.isNotEmpty ? route.waveStatus : item.status,
      route.status,
    );
    if (status == item.status) return item;
    return WaveListItem(
      waveId: item.waveId,
      routeId: item.routeId,
      routeNumber: item.routeNumber,
      status: status,
      plannedDistanceMeters: item.plannedDistanceMeters,
      plannedStart: item.plannedStart,
      createdAt: item.createdAt,
    );
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
    // Só as mais recentes: a tela pagina localmente de 20 em 20 e o
    // histórico inteiro crescia uma página (uma ida e volta) a cada 100.
    try {
      final results = await Future.wait([
        apiClient.getRecentPages('/api/v1/delivery/rotas/'),
        _getWavesAllowed(),
      ]).timeout(OfflineDeadline.read);
      unawaited(
        _listStore.save(0, {'routes': results[0], 'waves': results[1]}),
      );
      _prefetchReadyRoutes(results[0]);
      return _WaveListSnapshot(DateTime.now(), results[0], results[1]);
    } catch (error) {
      // Sem sinal: a última lista salva, com o status calculado no aparelho.
      if (!isOfflineError(error)) rethrow;
      final stored = await _listStore.read(0);
      if (stored == null) rethrow;
      List<Map<String, dynamic>> list(String key) => [
        for (final item in stored[key] is List ? stored[key] as List : [])
          if (item is Map) Map<String, dynamic>.from(item),
      ];
      return _WaveListSnapshot(DateTime.now(), list('routes'), list('waves'));
    }
  }

  /// Rotas já liberadas e ainda não iniciadas, baixadas para o aparelho.
  ///
  /// O servidor roteiriza sozinho ao fim da retirada, com o entregador ainda
  /// no armazém; baixar a rota agora é o que deixa o mapa abrir e a rota
  /// começar mesmo que o sinal caia antes de ele entrar na carga.
  void _prefetchReadyRoutes(List<Map<String, dynamic>> routes) {
    final service = activeRoutes;
    if (service == null) return;
    const ready = {'planned', 'released', 'accepted'};
    for (final route in routes) {
      final routeId = _asInt(route['id']);
      if (routeId == null || !ready.contains(route['status']?.toString())) {
        continue;
      }
      if (!_prefetchedRoutes.add(routeId)) continue;
      unawaited(
        service
            .getRoute(routeId)
            .then(
              (_) {},
              // Tenta de novo na próxima leitura da lista.
              onError: (Object _) => _prefetchedRoutes.remove(routeId),
            ),
      );
    }
  }

  Future<List<Map<String, dynamic>>> _getWavesAllowed() async {
    try {
      return await apiClient.getRecentPages('/api/v1/delivery/waves/');
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

  /// Detalhe da carga. Sem sinal, monta a partir das cópias no aparelho
  /// (rota e conferência) com as ações ainda não enviadas aplicadas.
  Future<WaveDetails> getWaveDetails(WaveListItem wave) async {
    try {
      final details = await _fetchWaveDetails(
        wave,
      ).timeout(OfflineDeadline.read);
      // Deixa a rota salva no aparelho para o mapa abrir sem sinal depois.
      final routeId = details.routeId;
      if (routeId != null) {
        unawaited(
          activeRoutes?.getRoute(routeId).then((_) {}, onError: (_) {}),
        );
      }
      return _withLocalDetails(details);
    } catch (error) {
      if (!isOfflineError(error)) rethrow;
      final offline = await _offlineDetails(wave);
      if (offline == null) rethrow;
      return offline;
    }
  }

  Future<WaveDetails> _withLocalDetails(WaveDetails details) async {
    final local = await _withLocalStatus(
      WaveListItem(
        waveId: details.waveId,
        routeId: details.routeId,
        routeNumber: details.routeNumber,
        status: details.status,
        plannedDistanceMeters: details.plannedDistanceMeters,
        plannedStart: details.plannedStart,
        createdAt: null,
      ),
    );
    final routeId = details.routeId;
    final route = routeId == null
        ? null
        : await activeRoutes?.storedRoute(routeId).catchError((_) => null);
    final stopStatus = {
      for (final stop in route?.stops ?? const <ActiveRouteStop>[])
        stop.stopId: stop.status,
    };
    return WaveDetails(
      waveId: details.waveId,
      routeId: details.routeId,
      routeNumber: details.routeNumber,
      status: local.status,
      plannedDistanceMeters: details.plannedDistanceMeters,
      plannedDurationSeconds: details.plannedDurationSeconds,
      plannedStart: details.plannedStart,
      plannedEnd: details.plannedEnd,
      orders: [
        for (final order in details.orders)
          stopStatus[order.stopId] == null ||
                  stopStatus[order.stopId] == order.stopStatus
              ? order
              : order.withStopStatus(stopStatus[order.stopId]!),
      ],
      pickup: details.pickup,
    );
  }

  Future<WaveDetails?> _offlineDetails(WaveListItem wave) async {
    final routeId = wave.routeId;
    final route = routeId == null
        ? null
        : await activeRoutes?.storedRoute(routeId).catchError((_) => null);
    final pickupRaw = await _storedPickup(wave.waveId);
    if (route == null && pickupRaw == null) return null;
    final pickup = pickupRaw == null
        ? PickupProgress.disabled(wave.waveId)
        : _localPickup(wave.waveId, pickupRaw);
    final local = await _withLocalStatus(wave);
    return WaveDetails(
      waveId: wave.waveId,
      routeId: routeId,
      routeNumber: route?.routeNumber ?? wave.routeNumber,
      status: local.status,
      plannedDistanceMeters: wave.plannedDistanceMeters,
      plannedDurationSeconds: 0,
      plannedStart: wave.plannedStart,
      plannedEnd: null,
      orders: route != null
          ? [
              for (final stop in route.stops)
                WaveOrderItem(
                  stopId: stop.stopId,
                  sequence: stop.sequence,
                  stopStatus: stop.status,
                  plannedEta: stop.plannedEta,
                  orderId: stop.orderId,
                  orderNumber: stop.orderNumber,
                  customerName: stop.customerName,
                  address: stop.fullAddress,
                  city: '',
                  state: '',
                  units: stop.units,
                  weightGrams: stop.weightGrams,
                ),
            ]
          : [
              for (final (index, order) in pickup.orders.indexed)
                WaveOrderItem(
                  stopId: 0,
                  sequence: index + 1,
                  stopStatus: order.isPickedUp ? 'ready' : 'awaiting_pickup',
                  plannedEta: null,
                  orderId: order.orderId,
                  orderNumber: order.orderNumber,
                  customerName: order.customer,
                  address: '',
                  city: '',
                  state: '',
                  units: order.totalLabels,
                  weightGrams: 0,
                ),
            ],
      pickup: pickup,
    );
  }

  Future<WaveDetails> _fetchWaveDetails(WaveListItem wave) async {
    final routeId = wave.routeId;
    final refreshToken = DateTime.now().microsecondsSinceEpoch;
    final freshQuery = {'_detail_refresh': refreshToken};
    final noCache = Options(
      headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
    );
    // As consultas são independentes: em paralelo, o detalhe abre no tempo
    // da mais lenta, não na soma das seis (cada ida e volta no 4G pesa).
    final pickupFuture = getPickupProgress(wave.waveId);
    final waveDataFuture = _getOptionalMap(
      '/api/v1/delivery/waves/${wave.waveId}/',
      queryParameters: freshQuery,
      options: noCache,
    );
    final routeFuture = routeId == null
        ? Future.value(const <String, dynamic>{})
        : _getOptionalMap(
            '/api/v1/delivery/rotas/$routeId/',
            queryParameters: freshQuery,
            options: noCache,
          );
    final stopsFuture = routeId == null
        ? Future.value(const <Map<String, dynamic>>[])
        : _getAll(
            '/api/v1/delivery/paradas/',
            queryParameters: {'route': routeId, ...freshQuery},
            options: noCache,
          );
    final linksFuture = _getAllOptional(
      '/api/v1/delivery/pedidos-wave/',
      queryParameters: {'wave': wave.waveId, ...freshQuery},
      options: noCache,
    );
    final ordersFuture = _getAll(
      '/api/v1/delivery/pedidos/',
      queryParameters: {'wave': wave.waveId, ...freshQuery},
      options: noCache,
    );
    // Evita erro "não tratado" das demais enquanto a primeira é aguardada.
    for (final future in <Future<Object?>>[
      pickupFuture,
      waveDataFuture,
      routeFuture,
      stopsFuture,
      linksFuture,
      ordersFuture,
    ]) {
      future.ignore();
    }
    final pickup = await pickupFuture;
    final waveData = await waveDataFuture;
    final route = await routeFuture;
    final stops = await stopsFuture;
    final routeStops = stops
        .where((item) => _asInt(item['route']) == routeId)
        .toList();

    // WaveOrder existe desde a criação da wave, antes das RouteStops.
    final links = await linksFuture;
    final waveLinks =
        links
            .where(
              (item) =>
                  _relationId(item['wave'] ?? item['wave_id']) == wave.waveId,
            )
            .toList()
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

    final orders = await ordersFuture;
    final ordersById = <int, Map<String, dynamic>>{};
    final currentOrderIds = <int>{};
    for (final order in orders) {
      final id = _asInt(order['id']);
      if (id == null) continue;
      ordersById[id] = order;
      // O servidor ignora `?wave=` (o pedido não tem campo de carga) e devolve
      // todos os pedidos do entregador — inclusive os da carga anterior. Por
      // isso esta lista só completa os dados; quem diz o que é da carga são
      // as paradas da rota, a conferência de retirada e os vínculos abaixo.
      final linkedWave = _relationId(
        order['wave'] ?? order['wave_id'] ?? order['delivery_wave'],
      );
      if (linkedWave == wave.waveId) currentOrderIds.add(id);
    }
    // A conferência lista exatamente os pedidos da carga (WaveOrder), mesmo
    // antes de existir rota — é o que deixa a lista aparecer na retirada.
    final pickupById = <int, PickupOrder>{
      for (final order in pickup.orders)
        if (order.orderId > 0) order.orderId: order,
    };
    currentOrderIds.addAll(pickupById.keys);
    for (final stop in routeStops) {
      final orderId = _relationId(stop['order']);
      if (orderId != null && stop['status']?.toString() != 'cancelled') {
        currentOrderIds.add(orderId);
      }
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
        final id = item.containsKey('order')
            ? _relationId(item['order']) ?? _asInt(nested['id'])
            : _asInt(nested['id']);
        if (id != null) {
          currentOrderIds.add(id);
          if (nested.length > 1) ordersById[id] = nested;
        }
      }
    }
    for (final link in waveLinks) {
      final id = _relationId(link['order'] ?? link['order_id']);
      if (id == null) continue;
      currentOrderIds.add(id);
      if (link['order'] is Map) {
        ordersById[id] = Map<String, dynamic>.from(link['order'] as Map);
      }
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
      final orderId = _relationId(stop['order']);
      if (stop['status']?.toString() != 'cancelled' &&
          currentOrderIds.contains(orderId)) {
        addOrderId(orderId);
      }
    }
    for (final link in waveLinks) {
      addOrderId(_relationId(link['order'] ?? link['order_id']));
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
    pickupById.keys.forEach(addOrderId);
    for (final order in orders) {
      final orderId = _asInt(order['id']);
      if (currentOrderIds.contains(orderId)) addOrderId(orderId);
    }

    final waveOrders = <WaveOrderItem>[];
    for (var index = 0; index < orderedIds.length; index++) {
      final orderId = orderedIds[index];
      final stop = stopsByOrder[orderId];
      final picked = pickupById[orderId];
      // Pedido ainda sem parada não aparece em /pedidos/ para o entregador:
      // número e cliente vêm da conferência.
      final order =
          ordersById[orderId] ??
          <String, dynamic>{
            if (picked != null && picked.orderNumber.isNotEmpty)
              'order_number': picked.orderNumber,
            if (picked != null) 'customer_name': picked.customer,
            if (picked != null)
              'status': picked.isPickedUp ? 'ready' : 'awaiting_pickup',
            if (picked != null) 'units': picked.totalLabels,
          };
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

  /// Conferência da carga. Sem sinal, usa a última cópia salva no aparelho
  /// com as leituras ainda não enviadas por cima.
  Future<PickupProgress> getPickupProgress(int waveId) async {
    // Antes da requisição: leitura confirmada depois disto é sobreposta.
    final fetchedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final response = await apiClient.dio
          .get<dynamic>(
            '/api/v1/delivery/waves/$waveId/retirada/',
            queryParameters: {
              '_detail_refresh': DateTime.now().microsecondsSinceEpoch,
            },
            options: Options(
              headers: const {
                'Cache-Control': 'no-cache',
                'Pragma': 'no-cache',
              },
            ),
          )
          .timeout(OfflineDeadline.read);
      if (response.data is Map) {
        final raw = applyLocalPickup(
          Map<String, dynamic>.from(response.data as Map),
          waveId,
          sync.confirmedEvents(fetchedAt: DateTime.parse(fetchedAt)),
        )..['fetched_at'] = fetchedAt;
        _pickupRaw[waveId] = raw;
        unawaited(_pickupStore.save(waveId, raw));
      }
      return _localPickup(waveId, _pickupRaw[waveId] ?? response.data);
    } on TimeoutException {
      final raw = await _storedPickup(waveId);
      if (raw != null) return _localPickup(waveId, raw);
      throw const WaveServiceException(
        'Sem conexão e sem cópia desta carga no aparelho. Abra a '
        'conferência uma vez com internet para poder conferir sem sinal.',
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 405) {
        return PickupProgress.disabled(waveId);
      }
      if (OfflineRequestQueue.isNetworkFailure(error)) {
        final raw = await _storedPickup(waveId);
        if (raw != null) return _localPickup(waveId, raw);
        throw const WaveServiceException(
          'Sem conexão e sem cópia desta carga no aparelho. Abra a '
          'conferência uma vez com internet para poder conferir sem sinal.',
        );
      }
      throw WaveServiceException(_errorMessage(error));
    }
  }

  Future<Map<String, dynamic>?> _storedPickup(int waveId) async {
    final cached = _pickupRaw[waveId];
    if (cached != null) return cached;
    final stored = await _pickupStore.read(waveId);
    // Uma leitura do servidor chegou enquanto o disco era lido: vale ela.
    final newer = _pickupRaw[waveId];
    if (newer != null) return newer;
    if (stored != null) _pickupRaw[waveId] = stored;
    return stored;
  }

  Map<String, dynamic> _localPickupRaw(int waveId, Object? raw) {
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    return applyLocalPickup(
      data,
      waveId,
      sync.localEvents(
        fetchedAt: DateTime.tryParse(data['fetched_at']?.toString() ?? ''),
      ),
    );
  }

  PickupProgress _localPickup(int waveId, Object? raw) =>
      WaveService.parsePickupProgress(_localPickupRaw(waveId, raw), waveId);

  /// Bipa uma etiqueta. A validação usa a cópia local com as mesmas regras
  /// da API; a leitura é salva no aparelho e enviada em segundo plano.
  Future<PickupProgress> registerPickup({
    required int waveId,
    required String code,
  }) async {
    if (code.trim().isEmpty) {
      throw const WaveServiceException('Informe o código da etiqueta.');
    }
    var raw = await _storedPickup(waveId);
    if (raw == null) {
      await getPickupProgress(waveId);
      raw = await _storedPickup(waveId);
    }
    var check = matchPickupCode(_localPickupRaw(waveId, raw), code);
    if (check.match == null && check.refusal!.startsWith('Nenhum pedido')) {
      // A carga pode ter mudado (pedido transferido para ela): com sinal,
      // confere a versão atual antes de recusar.
      try {
        await getPickupProgress(waveId);
        check = matchPickupCode(
          _localPickupRaw(waveId, await _storedPickup(waveId)),
          code,
        );
      } on WaveServiceException {
        // Sem rede vale a cópia local.
      }
    }
    final match = check.match;
    if (match == null) throw WaveServiceException(check.refusal!);
    await sync.record(
      kind: SyncKind.pickupScan,
      resourceKey: 'wave:$waveId',
      description: 'Conferir etiqueta ${match.code}',
      fields: {'wave_id': waveId, 'code': match.code},
    );
    invalidateCache();
    return _localPickup(waveId, await _storedPickup(waveId));
  }

  /// Marca um pedido da carga como "não vai".
  ///
  /// A API tira o pedido desta carga e desmembra o que ficou numa nota nova em
  /// `manual_assignment`. Sem sinal, o pedido sai da conferência na hora e a
  /// nota nova é criada quando a ação chegar ao servidor.
  Future<PickupProgress> markOrderNotGoing({
    required int waveId,
    required int orderId,
  }) async {
    final raw = await _storedPickup(waveId);
    final local = _localPickup(waveId, raw);
    if (!local.orders.any((order) => order.orderId == orderId)) {
      throw const WaveServiceException(
        'Este pedido não pertence a esta carga.',
      );
    }
    await sync.record(
      kind: SyncKind.pickupNotGoing,
      resourceKey: 'wave:$waveId',
      description: 'Marcar pedido que não vai',
      fields: {'wave_id': waveId, 'order_id': orderId},
    );
    invalidateCache();
    return _localPickup(waveId, raw);
  }

  /// Leitura confirmada pelo servidor: a cópia salva passa a contê-la.
  Future<void> _onSyncApplied(SyncApplied applied) async {
    final kind = applied.event.kind;
    if (kind != SyncKind.pickupScan && kind != SyncKind.pickupNotGoing) {
      return;
    }
    final waveId = applied.event.intField('wave_id');
    if (waveId == null) return;
    final raw = await _storedPickup(waveId);
    if (raw == null) return;
    if (kind == SyncKind.pickupScan) {
      markPickupScanned(
        raw,
        applied.event.fields['code']?.toString() ?? '',
        applied.event.occurredAt,
      );
    } else {
      removePickupOrder(raw, applied.event.intField('order_id'));
    }
    _pickupRaw[waveId] = raw;
    await _pickupStore.save(waveId, raw);
  }

  Future<Map<String, dynamic>> _getOptionalMap(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    try {
      final response = await apiClient.dio.get<dynamic>(
        path,
        queryParameters: queryParameters,
        options: options,
      );
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
    Options? options,
  }) async {
    try {
      return await _getAll(
        path,
        queryParameters: queryParameters,
        options: options,
      );
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

  /// Quanto esperar a roteirização antes de seguir com ela na fila.
  static const prepareWait = Duration(seconds: 45);

  /// Roteirizar depende do servidor. A ação entra na fila **depois** das
  /// leituras de retirada feitas sem sinal: o servidor só roteiriza a carga
  /// com a conferência completa, então a ordem de envio importa.
  Future<OfflineMutationResult<WaveListItem>> optimizeAndRelease(
    WaveListItem wave,
  ) async {
    try {
      return await apiClient.offlineRequests.enqueue<WaveListItem>(
        resourceKey: 'wave:${wave.waveId}',
        description: 'Preparar rota da carga',
        operation: (key) => _optimizeAndReleaseRequest(wave, key),
        persisted: PersistedOfflineRequest(
          type: _prepareRouteType,
          payload: {'wave_id': wave.waveId},
        ),
        waitFor: prepareWait,
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
      await _postPrepareRoute(wave.waveId, idempotencyKey);
      invalidateCache();
      final routes = await _getAll(
        '/api/v1/delivery/rotas/',
        queryParameters: {'wave': wave.waveId},
      );
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

  Future<void> _postPrepareRoute(int waveId, String idempotencyKey) async {
    try {
      await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/waves/$waveId/prepare-route/',
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
        '/api/v1/delivery/waves/$waveId/optimize/',
        options: apiClient.offlineRequests.requestOptions(
          idempotencyKey,
          step: 'optimize',
        ),
      );
      await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/waves/$waveId/release/',
        options: apiClient.offlineRequests.requestOptions(
          idempotencyKey,
          step: 'release',
        ),
      );
    }
  }

  static const routeInProgressMessage =
      'Você já tem uma rota em andamento. Conclua-a antes de iniciar outra.';

  /// Mesma regra do servidor (`execution.start_route`): uma rota em
  /// andamento por vez. Sem ela, sem sinal o app iniciava a segunda rota e o
  /// servidor recusava depois — a rota nunca constava como iniciada.
  /// Devolve o motivo da recusa, ou `null` se pode iniciar.
  Future<String?> otherRouteInProgress(int routeId) async {
    final serverStatus = <int, String>{};
    try {
      final snapshot = await _getListSnapshot(refresh: true);
      for (final route in snapshot.routes) {
        final id = _asInt(route['id']);
        if (id != null && id != routeId) {
          serverStatus[id] = route['status']?.toString() ?? '';
        }
      }
    } catch (_) {
      // Sem lista nenhuma: vale o que o aparelho sabe.
    }
    // Só as ainda não enviadas: uma confirmada já está na lista do servidor.
    final startedHere = {
      for (final event in sync.pending)
        if (event.kind == SyncKind.routeStart) ?event.intField('route_id'),
    }..remove(routeId);
    final candidates = {
      for (final entry in serverStatus.entries)
        if (entry.value == 'started') entry.key,
      ...startedHere,
    };
    for (final id in candidates) {
      ActiveRoute? local;
      try {
        local = await activeRoutes?.storedRoute(id);
      } catch (_) {}
      // A cópia traz as baixas feitas no aparelho (a rota pode já ter
      // terminado aqui, ainda sem o servidor saber). Só libera se a rota
      // estiver encerrada: uma cópia antiga ainda "liberada" não desmente o
      // servidor dizendo que ela está em andamento.
      if (liveRouteStatuses.contains(local?.status ?? 'started')) {
        return routeInProgressMessage;
      }
    }
    return null;
  }

  /// Iniciar a rota vale na hora no aparelho; o servidor recebe depois.
  Future<OfflineMutationResult<void>> startRoute(int routeId) async {
    final blocked = await otherRouteInProgress(routeId);
    if (blocked != null) throw WaveServiceException(blocked);
    await sync.record(
      kind: SyncKind.routeStart,
      resourceKey: 'route:$routeId',
      description: 'Iniciar rota',
      fields: {'route_id': routeId},
    );
    invalidateCache();
    return const OfflineMutationResult.queued();
  }

  Future<List<Map<String, dynamic>>> _getAll(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) => apiClient.getAllPages(
    path,
    queryParameters: queryParameters,
    options: options,
  );

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
