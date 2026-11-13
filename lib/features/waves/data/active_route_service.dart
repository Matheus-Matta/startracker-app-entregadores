import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/network/api_collection.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/offline_request_queue.dart';
import '../../../core/storage/session_storage.dart';
import '../../auth/data/delivery_configuration.dart';

class ActiveRoute {
  const ActiveRoute({
    required this.routeId,
    required this.waveId,
    required this.routeNumber,
    required this.status,
    required this.path,
    required this.deliveryWaypoints,
    required this.warehouse,
    required this.stops,
  });

  final int routeId;
  final int waveId;
  final String routeNumber;
  final String status;
  final List<RouteCoordinate> path;
  final Map<int, RouteCoordinate> deliveryWaypoints;
  final RoutePlace? warehouse;
  final List<ActiveRouteStop> stops;

  ActiveRouteStop? get currentStop {
    // A lista ja vem ordenada por sequence. Depois de um skip, a parada
    // anterior pode continuar temporariamente como approaching na resposta;
    // ainda assim a primeira pendente da nova sequencia deve assumir o mapa.
    for (final stop in stops) {
      if (!stop.isTerminal) return stop;
    }
    return null;
  }

  ActiveRoute copyWith({String? status, List<ActiveRouteStop>? stops}) =>
      ActiveRoute(
        routeId: routeId,
        waveId: waveId,
        routeNumber: routeNumber,
        status: status ?? this.status,
        path: path,
        deliveryWaypoints: deliveryWaypoints,
        warehouse: warehouse,
        stops: stops ?? this.stops,
      );
}

class RouteCoordinate {
  const RouteCoordinate(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

class RoutePlace {
  const RoutePlace({required this.name, required this.coordinate});

  final String name;
  final RouteCoordinate coordinate;
}

class DeliveryContentItem {
  const DeliveryContentItem({
    required this.id,
    required this.name,
    required this.volumeCount,
    required this.status,
    required this.failureReason,
    required this.failureNotes,
  });

  final int id;
  final String name;
  final int volumeCount;
  final String status;
  final String failureReason;
  final String failureNotes;
}

class ActiveRouteStop {
  const ActiveRouteStop({
    required this.stopId,
    required this.orderId,
    required this.sequence,
    required this.status,
    required this.orderStatus,
    required this.isManual,
    required this.plannedEta,
    required this.orderNumber,
    required this.customerName,
    required this.customerPhone,
    required this.fullAddress,
    required this.latitude,
    required this.longitude,
    required this.units,
    required this.weightGrams,
    required this.contents,
    required this.proofOverrides,
    required this.policy,
    required this.existingProofId,
    required this.existingPhotoCount,
    required this.hasSignature,
    required this.existingRecipientName,
    required this.existingRecipientDocument,
    required this.existingNotes,
    this.confirmationLocation = ConfirmationLocationPolicy.disabled,
  });

  final int stopId;
  final int orderId;
  final int sequence;
  final String status;
  final String orderStatus;
  final bool isManual;
  final DateTime? plannedEta;
  final String orderNumber;
  final String customerName;
  final String customerPhone;
  final String fullAddress;
  final double? latitude;
  final double? longitude;
  final int units;
  final int weightGrams;
  final List<DeliveryContentItem> contents;
  final Map<String, dynamic> proofOverrides;
  final CompletionPolicy policy;
  final int? existingProofId;
  final int existingPhotoCount;
  final bool hasSignature;
  final String existingRecipientName;
  final String existingRecipientDocument;
  final String existingNotes;
  final ConfirmationLocationPolicy confirmationLocation;

  bool get isTerminal =>
      const {'completed', 'failed', 'skipped', 'cancelled'}.contains(status);

  ActiveRouteStop withPolicy(
    CompletionPolicy nextPolicy, {
    ConfirmationLocationPolicy? confirmationLocation,
  }) => ActiveRouteStop(
    stopId: stopId,
    orderId: orderId,
    sequence: sequence,
    status: status,
    orderStatus: orderStatus,
    isManual: isManual,
    plannedEta: plannedEta,
    orderNumber: orderNumber,
    customerName: customerName,
    customerPhone: customerPhone,
    fullAddress: fullAddress,
    latitude: latitude,
    longitude: longitude,
    units: units,
    weightGrams: weightGrams,
    contents: contents,
    proofOverrides: proofOverrides,
    policy: nextPolicy,
    existingProofId: existingProofId,
    existingPhotoCount: existingPhotoCount,
    hasSignature: hasSignature,
    existingRecipientName: existingRecipientName,
    existingRecipientDocument: existingRecipientDocument,
    existingNotes: existingNotes,
    confirmationLocation: confirmationLocation ?? this.confirmationLocation,
  );

  ActiveRouteStop copyWith({String? status, String? orderStatus}) =>
      ActiveRouteStop(
        stopId: stopId,
        orderId: orderId,
        sequence: sequence,
        status: status ?? this.status,
        orderStatus: orderStatus ?? this.orderStatus,
        isManual: isManual,
        plannedEta: plannedEta,
        orderNumber: orderNumber,
        customerName: customerName,
        customerPhone: customerPhone,
        fullAddress: fullAddress,
        latitude: latitude,
        longitude: longitude,
        units: units,
        weightGrams: weightGrams,
        contents: contents,
        proofOverrides: proofOverrides,
        policy: policy,
        existingProofId: existingProofId,
        existingPhotoCount: existingPhotoCount,
        hasSignature: hasSignature,
        existingRecipientName: existingRecipientName,
        existingRecipientDocument: existingRecipientDocument,
        existingNotes: existingNotes,
        confirmationLocation: confirmationLocation,
      );
}

class CompletionPolicy {
  const CompletionPolicy({
    required this.requirePhoto,
    required this.minimumPhotos,
    required this.maximumPhotos,
    required this.requireSignature,
    required this.requireRecipientName,
    required this.requireDocument,
    required this.requireNoteOnFailure,
    required this.captureTimestamp,
    required this.version,
  });

  final bool requirePhoto;
  final int minimumPhotos;
  final int maximumPhotos;
  final bool requireSignature;
  final bool requireRecipientName;
  final bool requireDocument;
  final bool requireNoteOnFailure;
  final bool captureTimestamp;
  final int version;

  factory CompletionPolicy.fromConfiguration(
    Map<String, dynamic> configuration, {
    Map<String, dynamic> overrides = const {},
  }) {
    dynamic value(String key, dynamic fallback) {
      final overridden = overrides[key];
      if (overrides.containsKey(key) && overridden != null) return overridden;
      final configured = configuration[key];
      return configuration.containsKey(key) && configured != null
          ? configured
          : fallback;
    }

    final requirePhoto = _asBool(value('require_photo', true), fallback: true);
    final minimum = _asInt(value('minimum_photos', 1)) ?? 1;
    final configuredMaximum = _asInt(value('maximum_photos', 5)) ?? 5;
    final maximum = configuredMaximum < 1 ? 1 : configuredMaximum;
    return CompletionPolicy(
      requirePhoto: requirePhoto,
      minimumPhotos: requirePhoto ? minimum.clamp(0, maximum) : 0,
      maximumPhotos: maximum,
      requireSignature: _asBool(
        value('require_signature', false),
        fallback: false,
      ),
      requireRecipientName: _asBool(
        value('require_recipient_name', true),
        fallback: true,
      ),
      requireDocument: _asBool(
        value('require_document', false),
        fallback: false,
      ),
      requireNoteOnFailure: _asBool(
        value('require_note_on_failure', true),
        fallback: true,
      ),
      captureTimestamp: _asBool(
        value('capture_timestamp', true),
        fallback: true,
      ),
      version: _asInt(value('version', 1)) ?? 1,
    );
  }

  factory CompletionPolicy.fromOverrides(Map<String, dynamic> overrides) =>
      CompletionPolicy.fromConfiguration(const {}, overrides: overrides);
}

class DeliveryPhotoUpload {
  const DeliveryPhotoUpload({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

class DeliveryItemResult {
  const DeliveryItemResult({
    required this.id,
    required this.status,
    this.reason = '',
    this.notes = '',
  });

  final int id;
  final String status;
  final String reason;
  final String notes;

  Map<String, dynamic> toJson() => {
    'id': id,
    'status': status,
    if (status == 'failed' && reason.trim().isNotEmpty) 'reason': reason.trim(),
    if (status == 'failed' && notes.trim().isNotEmpty) 'notes': notes.trim(),
  };
}

class DeliveryProofSubmission {
  const DeliveryProofSubmission({
    required this.stop,
    required this.recipientName,
    required this.recipientDocument,
    required this.notes,
    required this.photos,
    required this.signatureBytes,
    required this.latitude,
    required this.longitude,
    required this.itemResults,
  });

  final ActiveRouteStop stop;
  final String recipientName;
  final String recipientDocument;
  final String notes;
  final List<DeliveryPhotoUpload> photos;
  final Uint8List? signatureBytes;
  final double? latitude;
  final double? longitude;
  final List<DeliveryItemResult> itemResults;
}

class DeliveryAuditResult {
  const DeliveryAuditResult({
    required this.deliveryActualLat,
    required this.deliveryActualLng,
    required this.deliveryActualAddress,
    required this.deliveryDistanceFromPlannedM,
    required this.deliveryWithinPlannedRadius,
    required this.trackerLat,
    required this.trackerLng,
    required this.trackerPositionAt,
    required this.trackerDistanceM,
    required this.trackerValidationStatus,
    required this.trackerValidationLabel,
  });

  final double? deliveryActualLat;
  final double? deliveryActualLng;
  final String deliveryActualAddress;
  final double? deliveryDistanceFromPlannedM;
  final bool? deliveryWithinPlannedRadius;
  final double? trackerLat;
  final double? trackerLng;
  final DateTime? trackerPositionAt;
  final double? trackerDistanceM;
  final String trackerValidationStatus;
  final String trackerValidationLabel;

  bool get hasData =>
      trackerValidationLabel.isNotEmpty ||
      deliveryActualLat != null ||
      deliveryActualAddress.isNotEmpty;

  factory DeliveryAuditResult.fromResponse(dynamic response) {
    final data = _map(response);
    final proof = _map(data['proof']);
    final source = proof.isEmpty ? data : proof;
    return DeliveryAuditResult(
      deliveryActualLat: _asDouble(source['delivery_actual_lat']),
      deliveryActualLng: _asDouble(source['delivery_actual_lng']),
      deliveryActualAddress:
          source['delivery_actual_address']?.toString() ?? '',
      deliveryDistanceFromPlannedM: _asDouble(
        source['delivery_distance_from_planned_m'],
      ),
      deliveryWithinPlannedRadius: _asNullableBool(
        source['delivery_within_planned_radius'],
      ),
      trackerLat: _asDouble(source['tracker_lat']),
      trackerLng: _asDouble(source['tracker_lng']),
      trackerPositionAt: DateTime.tryParse(
        source['tracker_position_at']?.toString() ?? '',
      ),
      trackerDistanceM: _asDouble(source['tracker_distance_m']),
      trackerValidationStatus:
          source['tracker_validation_status']?.toString() ?? '',
      trackerValidationLabel:
          source['tracker_validation_label']?.toString() ?? '',
    );
  }

  static Map<String, dynamic> _map(dynamic value) => value is Map
      ? Map<String, dynamic>.from(value)
      : const <String, dynamic>{};
}

class ActiveRouteException implements Exception {
  const ActiveRouteException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
}

class ActiveRouteService {
  ActiveRouteService(this.apiClient, {this.storage = const SessionStorage()}) {
    _registerOfflineHandlers();
    _queueSubscription = apiClient.offlineRequests.events.listen(
      _onOfflineQueueEvent,
    );
  }

  static const _warehouseCacheDuration = Duration(minutes: 30);
  static const _stopActionType = 'active_route.stop_action';
  static const _stopFailType = 'active_route.stop_fail';
  static const _stopCompleteType = 'active_route.stop_complete';
  static const routeStartType = 'active_route.route_start';

  final ApiClient apiClient;
  final SessionStorage storage;
  Map<String, dynamic>? _configurationCache;
  Future<String>? _mapStyleOperation;
  // Mantida viva durante todo o app (o serviço é um singleton).
  // ignore: unused_field
  late final StreamSubscription<OfflineQueueEvent> _queueSubscription;

  /// Última rota carregada com sucesso, por id. Serve para abrir o mapa
  /// instantaneamente e para continuar operando sem rede.
  final Map<int, ActiveRoute> _routeSnapshots = {};
  final Map<int, Future<ActiveRoute>> _routeOperations = {};

  /// Status aplicados localmente enquanto a alteração está na fila offline.
  final Map<int, String> _pendingStopStatuses = {};

  List<Map<String, dynamic>>? _warehouseCache;
  DateTime? _warehouseCacheAt;
  Future<List<Map<String, dynamic>>>? _warehouseOperation;

  static const openFreeMapStyle =
      'https://tiles.openfreemap.org/styles/positron';

  void invalidateCache() {
    _configurationCache = null;
    _mapStyleOperation = null;
    _warehouseCache = null;
    _warehouseCacheAt = null;
  }

  /// Limpa todos os dados da sessão (logout/troca de conta).
  void clearSessionData() {
    invalidateCache();
    _routeSnapshots.clear();
    _routeOperations.clear();
    _pendingStopStatuses.clear();
  }

  /// Rota em cache para exibição imediata enquanto a versão atual carrega.
  ActiveRoute? cachedRoute(int routeId) {
    final route = _routeSnapshots[routeId];
    return route == null ? null : _withPendingStatuses(route);
  }

  void _onOfflineQueueEvent(OfflineQueueEvent event) {
    if (event.type == OfflineQueueEventType.queued ||
        event.type == OfflineQueueEventType.exhausted) {
      return;
    }
    final key = event.resourceKey;
    if (!key.startsWith('stop:')) return;
    final stopId = int.tryParse(key.substring(5));
    if (stopId != null) _pendingStopStatuses.remove(stopId);
  }

  ActiveRoute _withPendingStatuses(ActiveRoute route) {
    if (_pendingStopStatuses.isEmpty) return route;
    var changed = false;
    final stops = route.stops.map((stop) {
      final status = _pendingStopStatuses[stop.stopId];
      if (status == null || status == stop.status || stop.isTerminal) {
        return stop;
      }
      changed = true;
      return stop.copyWith(
        status: status,
        orderStatus: switch (status) {
          'completed' => 'delivered',
          'failed' => 'delivery_failed',
          _ => null,
        },
      );
    }).toList();
    return changed ? route.copyWith(stops: stops) : route;
  }

  void _registerOfflineHandlers() {
    final queue = apiClient.offlineRequests;
    queue.registerRestoreHandler(_stopActionType, (key, payload, _) async {
      final stopId = _asInt(payload['stop_id']);
      final action = payload['action']?.toString() ?? '';
      if (stopId == null || action.isEmpty) return;
      await _postStopAction(stopId, action, key);
    });
    queue.registerRestoreHandler(_stopFailType, (key, payload, _) async {
      final stopId = _asInt(payload['stop_id']);
      if (stopId == null) return;
      await _postFailure(
        stopId: stopId,
        reason: payload['reason']?.toString() ?? '',
        notes: payload['notes']?.toString() ?? '',
        latitude: _asDouble(payload['lat']),
        longitude: _asDouble(payload['lon']),
        idempotencyKey: key,
      );
    });
    queue.registerRestoreHandler(routeStartType, (key, payload, _) async {
      final routeId = _asInt(payload['route_id']);
      if (routeId == null) return;
      await postRouteStart(routeId, key);
    });
    queue.registerRestoreHandler(_stopCompleteType, (
      key,
      payload,
      files,
    ) async {
      final plan = _CompletionPlan.fromJson(payload);
      if (plan.stopId <= 0) return;
      final state = await _serverCompletionState(plan.stopId);
      if (state.completed != null) return;
      await _runCompletionPlan(plan, files, key, resume: state);
    });
  }

  Future<List<Map<String, dynamic>>> _warehouses() {
    final cached = _warehouseCache;
    final cachedAt = _warehouseCacheAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _warehouseCacheDuration) {
      return Future.value(cached);
    }
    return _warehouseOperation ??= () async {
      try {
        final result = await _getAllOptional('/api/v1/delivery/armazens/');
        _warehouseCache = result;
        _warehouseCacheAt = DateTime.now();
        return result;
      } on DioException {
        // Armazém é apenas decoração do mapa: usa a última cópia conhecida.
        if (cached != null) return cached;
        rethrow;
      } finally {
        _warehouseOperation = null;
      }
    }();
  }

  Future<String> getMapStyle() => _mapStyleOperation ??= _loadMapStyle();

  /// Monta o estilo do mapa com uma única fonte de tiles.
  ///
  /// Antes o app baixava os tiles vetoriais do OpenFreeMap e, por cima, os
  /// tiles raster do Mapbox em `512@2x` (~1024 px cada) — a camada de baixo
  /// nunca aparecia e o 4G pagava as duas. Agora:
  /// * com Mapbox disponível: estilo mínimo só com o raster, em 512 px sem
  ///   `@2x` (um quarto dos pixels);
  /// * sem Mapbox: o estilo vetorial do OpenFreeMap, carregado direto pelo
  ///   MapLibre (que mantém cache em disco).
  Future<String> _loadMapStyle() async {
    try {
      final configResponse = await apiClient.dio.get<dynamic>(
        '/api/v1/mapbox/',
      );
      final config = _asMap(configResponse.data);
      final token = config['access_token']?.toString().trim() ?? '';
      final available = _asBool(
        config['available'],
        fallback: token.isNotEmpty,
      );
      if (!available || token.isEmpty) return openFreeMapStyle;
      return jsonEncode({
        'version': 8,
        'sources': {
          'startracker-mapbox': {
            'type': 'raster',
            'tiles': [
              'https://api.mapbox.com/styles/v1/mapbox/streets-v12/tiles/512/{z}/{x}/{y}?access_token=${Uri.encodeQueryComponent(token)}',
            ],
            'tileSize': 512,
            'maxzoom': 20,
            'attribution': '© Mapbox © OpenStreetMap',
          },
        },
        'layers': [
          {
            'id': 'startracker-background',
            'type': 'background',
            'paint': {'background-color': '#E8E7E1'},
          },
          {
            'id': 'startracker-mapbox-primary',
            'type': 'raster',
            'source': 'startracker-mapbox',
          },
        ],
      });
    } catch (_) {
      // Sem a configuração, o mapa vetorial gratuito continua funcionando.
      _mapStyleOperation = null;
      return openFreeMapStyle;
    }
  }

  Future<ActiveRouteStop> refreshCompletionPolicy(ActiveRouteStop stop) async {
    final configuration = await _deliveryConfiguration(refresh: true);
    return stop.withPolicy(
      CompletionPolicy.fromConfiguration(
        configuration,
        overrides: stop.proofOverrides,
      ),
      confirmationLocation: ConfirmationLocationPolicy.fromConfiguration(
        configuration,
      ),
    );
  }

  /// Busca a rota atualizada.
  ///
  /// Consultas simultâneas para a mesma rota compartilham a mesma requisição.
  /// Sem rede, devolve a última cópia conhecida (com as alterações que estão
  /// na fila offline) para o entregador continuar trabalhando.
  Future<ActiveRoute> getRoute(int routeId) {
    final ongoing = _routeOperations[routeId];
    if (ongoing != null) return ongoing;
    final operation = () async {
      try {
        final route = await _fetchRoute(routeId);
        _routeSnapshots[routeId] = route;
        return _withPendingStatuses(route);
      } on _RouteNetworkFailure catch (failure) {
        final cached = _routeSnapshots[routeId];
        if (cached != null) return _withPendingStatuses(cached);
        throw failure.exception;
      } finally {
        _routeOperations.remove(routeId);
      }
    }();
    _routeOperations[routeId] = operation;
    return operation;
  }

  Future<ActiveRoute> _fetchRoute(int routeId) async {
    try {
      final refreshToken = DateTime.now().microsecondsSinceEpoch;
      // A rota é consultada primeiro porque seu wave_id limita a carga de
      // pedidos abaixo. Antes, cada atualização do mapa baixava todos os
      // pedidos da conta.
      final routeResponse = await apiClient.dio.get<dynamic>(
        '/api/v1/delivery/rotas/$routeId/',
        queryParameters: {'_map_refresh': refreshToken},
        options: Options(
          headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
        ),
      );
      final route = _asMap(routeResponse.data);
      final waveId = _asInt(route['wave']);
      final results = await Future.wait<dynamic>([
        _deliveryConfiguration(),
        _getAll(
          '/api/v1/delivery/paradas/',
          queryParameters: {'route': routeId, '_map_refresh': refreshToken},
          noCache: true,
        ),
        _getAll(
          '/api/v1/delivery/pedidos/',
          queryParameters: {'wave': ?waveId, '_map_refresh': refreshToken},
          noCache: true,
        ),
        _warehouses(),
      ]);
      final deliveryConfig = results[0] as Map<String, dynamic>;
      final stops = (results[1] as List<Map<String, dynamic>>)
          .where(
            (item) =>
                _asInt(item['route']) == routeId &&
                item['status']?.toString() != 'cancelled',
          )
          .toList();
      // Antes, comprovantes e fotos vinham sem filtro: o histórico inteiro do
      // entregador a cada atualização do mapa. Agora só os desta rota.
      final proofItems = await _getAllByIds(
        '/api/v1/delivery/comprovantes/',
        'route_stop',
        [for (final stop in stops) ?_asInt(stop['id'])],
      );
      final photoItems = await _getAllByIds(
        '/api/v1/delivery/fotos-comprovante/',
        'delivery_proof',
        [for (final proof in proofItems) ?_asInt(proof['id'])],
      );
      final orders = {
        for (final item in results[2] as List<Map<String, dynamic>>)
          if (_asInt(item['id']) case final int id) id: item,
      };
      final warehouses = {
        for (final item in results[3] as List<Map<String, dynamic>>)
          if (_asInt(item['id']) case final int id) id: item,
      };
      final proofs = {
        for (final item in proofItems)
          if (_asInt(item['route_stop']) case final int stopId) stopId: item,
      };
      final photoCounts = <int, int>{};
      for (final photo in photoItems) {
        final proofId = _asInt(photo['delivery_proof']);
        if (proofId != null) {
          photoCounts.update(proofId, (count) => count + 1, ifAbsent: () => 1);
        }
      }

      final activeStops = <ActiveRouteStop>[];
      for (final stop in stops) {
        final stopId = _asInt(stop['id']);
        final orderId = _asInt(stop['order']);
        if (stopId == null || orderId == null) continue;
        final order = orders[orderId] ?? const <String, dynamic>{};
        final proof = proofs[stopId];
        final proofId = _asInt(proof?['id']);
        final overrides = order['proof_overrides'] is Map
            ? Map<String, dynamic>.from(order['proof_overrides'] as Map)
            : const <String, dynamic>{};
        activeStops.add(
          ActiveRouteStop(
            stopId: stopId,
            orderId: orderId,
            sequence: _asInt(stop['sequence']) ?? 0,
            status: stop['status']?.toString() ?? 'planned',
            orderStatus: order['status']?.toString() ?? '',
            isManual: _asBool(stop['is_manual'], fallback: false),
            plannedEta: DateTime.tryParse(
              stop['planned_eta']?.toString() ?? '',
            ),
            orderNumber: order['order_number']?.toString() ?? '#$orderId',
            customerName: order['customer_name']?.toString() ?? 'Cliente',
            customerPhone: order['customer_phone']?.toString() ?? '',
            fullAddress: _fullAddress(order),
            latitude: _asDouble(order['lat']),
            longitude: _asDouble(order['lon']),
            units: _asInt(order['units']) ?? 0,
            weightGrams: _asInt(order['weight']) ?? 0,
            contents: _parseContents(order['items']),
            proofOverrides: overrides,
            policy: CompletionPolicy.fromConfiguration(
              deliveryConfig,
              overrides: overrides,
            ),
            existingProofId: proofId,
            existingPhotoCount: proofId == null ? 0 : photoCounts[proofId] ?? 0,
            hasSignature:
                (proof?['signature_file']?.toString() ?? '').isNotEmpty,
            existingRecipientName: proof?['recipient_name']?.toString() ?? '',
            existingRecipientDocument:
                proof?['recipient_document']?.toString() ?? '',
            existingNotes: proof?['notes']?.toString() ?? '',
            confirmationLocation: ConfirmationLocationPolicy.fromConfiguration(
              deliveryConfig,
            ),
          ),
        );
      }
      activeStops.sort((a, b) => a.sequence.compareTo(b.sequence));
      final path = _parsePath(route['path_geometry']);
      final deliveryWaypoints = _parseDeliveryWaypoints(
        route['planned_waypoints'],
      );
      final plannedWarehouse = parseWarehouseWaypoint(
        route['planned_waypoints'],
      );
      final firstOrder = activeStops.isEmpty
          ? null
          : orders[activeStops.first.orderId];
      final orderWarehouse = firstOrder?['warehouse'];
      final embeddedWarehouse = _asMap(orderWarehouse);
      final warehouseId = orderWarehouse is Map
          ? _asInt(orderWarehouse['id'])
          : _asInt(orderWarehouse);
      final warehouseData = warehouses[warehouseId] ?? embeddedWarehouse;
      final warehouseCoordinate = _parseCoordinate(warehouseData);

      return ActiveRoute(
        routeId: _asInt(route['id']) ?? routeId,
        waveId: _asInt(route['wave']) ?? 0,
        routeNumber: route['route_number']?.toString() ?? 'Rota #$routeId',
        status: route['status']?.toString() ?? '',
        path: path,
        deliveryWaypoints: deliveryWaypoints,
        warehouse:
            plannedWarehouse ??
            (warehouseCoordinate == null
                ? null
                : RoutePlace(
                    name: warehouseData['name']?.toString() ?? 'Armazém',
                    coordinate: warehouseCoordinate,
                  )),
        stops: activeStops,
      );
    } on DioException catch (error) {
      final exception = ActiveRouteException(
        _errorMessage(error),
        statusCode: error.response?.statusCode,
      );
      if (OfflineRequestQueue.isNetworkFailure(error)) {
        throw _RouteNetworkFailure(exception);
      }
      throw exception;
    }
  }

  Future<OfflineMutationResult<void>> arrive(int stopId) =>
      _stopAction(stopId, 'arrive');

  Future<OfflineMutationResult<void>> begin(int stopId) =>
      _stopAction(stopId, 'begin');

  Future<OfflineMutationResult<void>> skip({required int stopId}) =>
      _stopAction(stopId, 'skip');

  Future<OfflineMutationResult<void>> startRoute(int routeId) async {
    try {
      return await apiClient.offlineRequests.execute<void>(
        resourceKey: 'route:$routeId',
        description: 'Iniciar rota',
        operation: (key) => postRouteStart(routeId, key),
        persisted: PersistedOfflineRequest(
          type: routeStartType,
          payload: {'route_id': routeId},
        ),
      );
    } on DioException catch (error) {
      throw ActiveRouteException(_errorMessage(error));
    }
  }

  Future<void> postRouteStart(int routeId, String idempotencyKey) async {
    await apiClient.dio.post<dynamic>(
      '/api/v1/delivery/rotas/$routeId/start/',
      options: apiClient.offlineRequests.requestOptions(idempotencyKey),
    );
  }

  Future<OfflineMutationResult<void>> fail({
    required int stopId,
    required String reason,
    required String notes,
    double? latitude,
    double? longitude,
  }) async {
    try {
      final result = await apiClient.offlineRequests.execute<void>(
        resourceKey: 'stop:$stopId',
        description: 'Registrar falha na entrega',
        operation: (key) => _postFailure(
          stopId: stopId,
          reason: reason,
          notes: notes,
          latitude: latitude,
          longitude: longitude,
          idempotencyKey: key,
        ),
        persisted: PersistedOfflineRequest(
          type: _stopFailType,
          payload: {
            'stop_id': stopId,
            'reason': reason,
            'notes': notes,
            'lat': ?latitude,
            'lon': ?longitude,
          },
        ),
      );
      if (result.queued) _pendingStopStatuses[stopId] = 'failed';
      return result;
    } on DioException catch (error) {
      throw ActiveRouteException(_errorMessage(error));
    }
  }

  Future<void> _postFailure({
    required int stopId,
    required String reason,
    required String notes,
    required double? latitude,
    required double? longitude,
    required String idempotencyKey,
  }) async {
    await apiClient.dio.post<dynamic>(
      '/api/v1/delivery/paradas/$stopId/fail/',
      data: {
        'reason': reason,
        'notes': notes,
        'lat': ?latitude,
        'lon': ?longitude,
      },
      options: apiClient.offlineRequests.requestOptions(idempotencyKey),
    );
  }

  Future<OfflineMutationResult<DeliveryAuditResult>> complete(
    DeliveryProofSubmission submission,
  ) async {
    final hasLatitude = submission.latitude != null;
    final hasLongitude = submission.longitude != null;
    if (hasLatitude != hasLongitude) {
      throw const ActiveRouteException(
        'Latitude e longitude devem ser registradas juntas.',
      );
    }
    if (submission.latitude case final latitude?
        when !latitude.isFinite || latitude < -90 || latitude > 90) {
      throw const ActiveRouteException('Latitude da entrega inválida.');
    }
    if (submission.longitude case final longitude?
        when !longitude.isFinite || longitude < -180 || longitude > 180) {
      throw const ActiveRouteException('Longitude da entrega inválida.');
    }
    final plan = _CompletionPlan.fromSubmission(
      submission,
      endpoint: _completionEndpoint(
        submission.stop.confirmationLocation,
        submission.stop.stopId,
      ),
      method: _completionMethod(submission.stop.confirmationLocation),
    );
    final files = <String, Uint8List>{
      if (submission.signatureBytes != null)
        _CompletionPlan.signatureFile: submission.signatureBytes!,
      for (final (index, photo) in submission.photos.indexed)
        _CompletionPlan.photoFile(index): photo.bytes,
    };
    var firstAttempt = true;
    try {
      final result = await apiClient.offlineRequests
          .execute<DeliveryAuditResult>(
            resourceKey: 'stop:${submission.stop.stopId}',
            description: 'Finalizar entrega',
            operation: (key) async {
              _ServerCompletionState? resume;
              if (!firstAttempt) {
                // A tentativa anterior pode ter gravado parte da baixa antes
                // de a resposta se perder no 4G: retoma do ponto em que o
                // servidor parou em vez de recriar o comprovante (400).
                resume = await _serverCompletionState(submission.stop.stopId);
                if (resume.completed case final completed?) return completed;
              }
              firstAttempt = false;
              return _runCompletionPlan(plan, files, key, resume: resume);
            },
            persisted: PersistedOfflineRequest(
              type: _stopCompleteType,
              payload: plan.toJson(),
              files: files,
            ),
          );
      if (result.queued) {
        _pendingStopStatuses[submission.stop.stopId] = 'completed';
      }
      return result;
    } on ActiveRouteException {
      rethrow;
    } on DioException catch (error) {
      throw ActiveRouteException(
        _errorMessage(error),
        statusCode: error.response?.statusCode,
      );
    }
  }

  Future<DeliveryAuditResult> _runCompletionPlan(
    _CompletionPlan plan,
    Map<String, Uint8List> files,
    String idempotencyKey, {
    _ServerCompletionState? resume,
  }) async {
    final signature = files[_CompletionPlan.signatureFile];
    final proofData = <String, dynamic>{
      // items e completed_at são resultados geridos pelo complete/.
      // Nunca devem fazer parte do multipart do comprovante.
      ...plan.proofFields,
      if (signature != null)
        'signature_file': MultipartFile.fromBytes(
          signature,
          filename: 'assinatura.png',
        ),
    };

    int proofId;
    if (resume?.proofId ?? plan.existingProofId case final int existingId) {
      final response = await apiClient.dio.patch<dynamic>(
        '/api/v1/delivery/comprovantes/$existingId/',
        data: FormData.fromMap(proofData),
        options: apiClient.offlineRequests.requestOptions(
          idempotencyKey,
          step: 'proof',
          upload: true,
        ),
      );
      proofId = _asInt(_asMap(response.data)['id']) ?? existingId;
    } else {
      final response = await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/comprovantes/',
        data: FormData.fromMap(proofData),
        options: apiClient.offlineRequests.requestOptions(
          idempotencyKey,
          step: 'proof',
          upload: true,
        ),
      );
      final createdId = _asInt(_asMap(response.data)['id']);
      if (createdId == null) {
        throw const ActiveRouteException(
          'O servidor não retornou o comprovante criado.',
        );
      }
      proofId = createdId;
    }

    var sequence = plan.photoSequenceStart;
    final uploadedSequences = resume?.photoSequences ?? const <int>{};
    for (final (index, filename) in plan.photoFilenames.indexed) {
      final bytes = files[_CompletionPlan.photoFile(index)];
      if (bytes == null) continue;
      final photoSequence = sequence++;
      // Foto já recebida numa tentativa anterior: reenviar daria 400
      // (sequência única por comprovante) e desfaria a entrega.
      if (uploadedSequences.contains(photoSequence)) continue;
      await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/fotos-comprovante/',
        data: FormData.fromMap({
          'delivery_proof': proofId,
          'sequence': photoSequence,
          'file': MultipartFile.fromBytes(bytes, filename: filename),
        }),
        options: apiClient.offlineRequests.requestOptions(
          idempotencyKey,
          step: 'photo-$index',
          upload: true,
        ),
      );
    }

    final response = await apiClient.dio.request<dynamic>(
      plan.endpoint,
      data: plan.completionData.isEmpty ? null : plan.completionData,
      options: apiClient.offlineRequests
          .requestOptions(idempotencyKey, step: 'complete')
          .copyWith(method: plan.method),
    );
    return DeliveryAuditResult.fromResponse(response.data);
  }

  /// O que já foi gravado no servidor para esta parada.
  ///
  /// Usado antes de reenviar uma baixa: o comprovante e parte das fotos podem
  /// ter sido gravados numa tentativa cuja resposta nunca chegou ao aparelho.
  Future<_ServerCompletionState> _serverCompletionState(int stopId) async {
    final response = await apiClient.dio.get<dynamic>(
      '/api/v1/delivery/paradas/$stopId/',
      options: Options(
        headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
      ),
    );
    final data = _asMap(response.data);
    if (data['status']?.toString() == 'completed') {
      return _ServerCompletionState(
        completed: DeliveryAuditResult.fromResponse(data),
      );
    }
    final rawProof = data['proof'];
    final proofId = rawProof is Map ? _asInt(rawProof['id']) : _asInt(rawProof);
    if (proofId == null) return const _ServerCompletionState();
    final photos = await _getAllByIds(
      '/api/v1/delivery/fotos-comprovante/',
      'delivery_proof',
      [proofId],
    );
    return _ServerCompletionState(
      proofId: proofId,
      photoSequences: {
        for (final photo in photos)
          if (_asInt(photo['sequence']) case final int sequence) sequence,
      },
    );
  }

  static String _completionEndpoint(
    ConfirmationLocationPolicy policy,
    int stopId,
  ) {
    if (policy.completeUrlTemplate.isEmpty) {
      // Compatibilidade com configuracoes anteriores ao contrato v6.
      return '/api/v1/delivery/paradas/$stopId/complete/';
    }
    final endpoint = policy.completionUrl(stopId);
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        uri.isAbsolute ||
        !uri.path.startsWith('/api/') ||
        endpoint.contains('{stop_id}')) {
      throw const ActiveRouteException(
        'Endpoint de conclusão inválido. Atualize a configuração.',
      );
    }
    return endpoint;
  }

  static String _completionMethod(ConfirmationLocationPolicy policy) {
    if (policy.method.isEmpty) return 'POST';
    if (!const {'POST', 'PUT', 'PATCH'}.contains(policy.method)) {
      throw const ActiveRouteException(
        'Método de conclusão inválido. Atualize a configuração.',
      );
    }
    return policy.method;
  }

  Future<OfflineMutationResult<void>> _stopAction(
    int stopId,
    String action, {
    Map<String, dynamic>? data,
  }) async {
    try {
      return await apiClient.offlineRequests.execute<void>(
        resourceKey: 'stop:$stopId',
        description: 'Atualizar etapa da entrega',
        operation: (key) => _postStopAction(stopId, action, key, data: data),
        persisted: data == null
            ? PersistedOfflineRequest(
                type: _stopActionType,
                payload: {'stop_id': stopId, 'action': action},
              )
            : null,
      );
    } on DioException catch (error) {
      throw ActiveRouteException(_errorMessage(error));
    }
  }

  Future<void> _postStopAction(
    int stopId,
    String action,
    String idempotencyKey, {
    Map<String, dynamic>? data,
  }) async {
    await apiClient.dio.post<dynamic>(
      '/api/v1/delivery/paradas/$stopId/$action/',
      data: data,
      options: apiClient.offlineRequests.requestOptions(idempotencyKey),
    );
  }

  Future<Map<String, dynamic>> _deliveryConfiguration({
    bool refresh = false,
  }) async {
    if (!refresh) {
      final configuration = _configurationCache;
      if (configuration != null) return configuration;
    }
    final cached = await storage.readDeliveryConfig();
    if (!refresh) {
      _configurationCache = cached;
      return cached;
    }

    try {
      final response = await apiClient.dio.get<dynamic>(
        '/api/v1/auth/entregadores/configuracao/',
      );
      final config = _configurationFromResponse(response.data);
      if (config.isNotEmpty) {
        await storage.saveDeliveryConfig(config);
        _configurationCache = config;
        return config;
      }
    } on DioException {
      // Login/cache continua sendo uma fonte segura quando a consulta falhar.
    }
    _configurationCache = cached;
    return cached;
  }

  static Map<String, dynamic> _configurationFromResponse(dynamic data) {
    return deliveryConfigurationFromResponse(data);
  }

  Future<List<Map<String, dynamic>>> _getAll(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool noCache = false,
  }) => apiClient.getAllPages(
    path,
    queryParameters: queryParameters,
    options: noCache
        ? Options(
            headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
          )
        : null,
  );

  /// Busca registros filtrando por uma lista de ids (`campo=1&campo=2`),
  /// em lotes para a URL não ficar longa demais.
  Future<List<Map<String, dynamic>>> _getAllByIds(
    String path,
    String field,
    List<int> ids,
  ) async {
    if (ids.isEmpty) return const [];
    const chunkSize = 40;
    final chunks = [
      for (var start = 0; start < ids.length; start += chunkSize)
        ids.sublist(
          start,
          start + chunkSize > ids.length ? ids.length : start + chunkSize,
        ),
    ];
    final pages = await Future.wait([
      for (final chunk in chunks)
        _getAll(
          path,
          queryParameters: {field: chunk.map((id) => '$id').toList()},
          noCache: true,
        ),
    ]);
    final wanted = ids.toSet();
    return [
      for (final page in pages)
        for (final item in page)
          // Servidor antigo que ignore o filtro não pode misturar outra rota.
          if (wanted.contains(_asInt(item[field]))) item,
    ];
  }

  Future<List<Map<String, dynamic>>> _getAllOptional(String path) async {
    try {
      return await _getAll(path);
    } on DioException catch (error) {
      if (error.response?.statusCode == 403 ||
          error.response?.statusCode == 404) {
        return const [];
      }
      rethrow;
    }
  }

  static List<DeliveryContentItem> _parseContents(dynamic value) {
    if (value is! List) return const [];
    final contents = <DeliveryContentItem>[];
    for (final raw in value) {
      final item = _asMap(raw);
      final name = item['name']?.toString().trim() ?? '';
      final volumes = item['volumes'];
      if (name.isEmpty) continue;
      contents.add(
        DeliveryContentItem(
          id: _asInt(item['id']) ?? 0,
          name: name,
          volumeCount: volumes is List ? volumes.length : 0,
          status: item['status']?.toString() ?? 'pending',
          failureReason: item['failure_reason']?.toString() ?? '',
          failureNotes: item['failure_notes']?.toString() ?? '',
        ),
      );
    }
    return contents;
  }

  static List<RouteCoordinate> _parsePath(dynamic value) {
    if (value is! Map || value['coordinates'] is! List) return const [];
    final result = <RouteCoordinate>[];
    for (final coordinate in value['coordinates'] as List) {
      if (coordinate is! List || coordinate.length < 2) continue;
      final lon = _asDouble(coordinate[0]);
      final lat = _asDouble(coordinate[1]);
      if (lat != null && lon != null) result.add(RouteCoordinate(lat, lon));
    }
    return result;
  }

  static Map<int, RouteCoordinate> _parseDeliveryWaypoints(dynamic value) {
    if (value is! List) return const {};
    final result = <int, RouteCoordinate>{};
    for (final raw in value) {
      final waypoint = _asMap(raw);
      if (waypoint['kind']?.toString() != 'delivery') continue;
      final orderId = _asInt(waypoint['order_id']);
      final location = waypoint['location'];
      if (orderId == null || location is! List || location.length < 2) {
        continue;
      }
      final longitude = _asDouble(location[0]);
      final latitude = _asDouble(location[1]);
      if (latitude != null && longitude != null) {
        result[orderId] = RouteCoordinate(latitude, longitude);
      }
    }
    return result;
  }

  static RoutePlace? parseWarehouseWaypoint(dynamic value) {
    if (value is! List) return null;
    for (final raw in value) {
      final waypoint = _asMap(raw);
      final kind = waypoint['kind']?.toString().toLowerCase();
      if (!const {'pickup', 'warehouse', 'origin'}.contains(kind)) continue;
      final coordinate = _parseCoordinate(waypoint);
      if (coordinate == null) continue;
      final name = waypoint['name']?.toString().trim() ?? '';
      return RoutePlace(
        name: name.isEmpty ? 'Armazém' : name,
        coordinate: coordinate,
      );
    }
    return null;
  }

  static RouteCoordinate? _parseCoordinate(dynamic value) {
    final data = _asMap(value);
    dynamic rawLocation = data['location'] ?? data['coordinates'];
    if (rawLocation is Map) {
      rawLocation = rawLocation['coordinates'];
    }
    if (rawLocation is List && rawLocation.length >= 2) {
      final longitude = _asDouble(rawLocation[0]);
      final latitude = _asDouble(rawLocation[1]);
      if (latitude != null && longitude != null) {
        return RouteCoordinate(latitude, longitude);
      }
    }
    final latitude = _asDouble(data['lat'] ?? data['latitude']);
    final longitude = _asDouble(
      data['lon'] ?? data['lng'] ?? data['longitude'],
    );
    return latitude == null || longitude == null
        ? null
        : RouteCoordinate(latitude, longitude);
  }

  static String _fullAddress(Map<String, dynamic> order) => [
    [
      order['address']?.toString() ?? '',
      order['address_number']?.toString() ?? '',
    ].where((part) => part.isNotEmpty).join(', '),
    order['address_complement']?.toString() ?? '',
    order['neighborhood']?.toString() ?? '',
    [
      order['city']?.toString() ?? '',
      order['state']?.toString() ?? '',
    ].where((part) => part.isNotEmpty).join('/'),
    order['postal_code']?.toString() ?? '',
  ].where((part) => part.isNotEmpty).join(' · ');

  static Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static String _errorMessage(DioException error) {
    final data = error.response?.data;
    final messages = _validationMessages(data).toSet().take(4).toList();
    if (messages.isNotEmpty) return messages.join('\n');
    return 'Não foi possível concluir a operação. Tente novamente.';
  }

  static Iterable<String> _validationMessages(dynamic value) sync* {
    if (value is String && value.trim().isNotEmpty) {
      yield value.trim();
    } else if (value is Iterable) {
      for (final item in value) {
        yield* _validationMessages(item);
      }
    } else if (value is Map) {
      for (final item in value.values) {
        yield* _validationMessages(item);
      }
    }
  }
}

bool _asBool(dynamic value, {required bool fallback}) => switch (value) {
  bool boolean => boolean,
  String text when text.toLowerCase() == 'true' => true,
  String text when text.toLowerCase() == 'false' => false,
  _ => fallback,
};

int? _asInt(dynamic value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text),
  _ => null,
};

double? _asDouble(dynamic value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text),
  _ => null,
};

bool? _asNullableBool(dynamic value) => switch (value) {
  bool boolean => boolean,
  String text when text.toLowerCase() == 'true' => true,
  String text when text.toLowerCase() == 'false' => false,
  num number => number != 0,
  _ => null,
};

class _RouteNetworkFailure implements Exception {
  const _RouteNetworkFailure(this.exception);

  final ActiveRouteException exception;
}

/// Finalização de entrega já resolvida em dados simples, para poder ser
/// salva em disco e reenviada depois que o app for reaberto.
class _ServerCompletionState {
  const _ServerCompletionState({
    this.completed,
    this.proofId,
    this.photoSequences = const {},
  });

  /// Preenchido quando a parada já está concluída no servidor.
  final DeliveryAuditResult? completed;
  final int? proofId;
  final Set<int> photoSequences;
}

class _CompletionPlan {
  const _CompletionPlan({
    required this.stopId,
    required this.endpoint,
    required this.method,
    required this.existingProofId,
    required this.photoSequenceStart,
    required this.proofFields,
    required this.photoFilenames,
    required this.completionData,
  });

  static const signatureFile = 'signature';
  static String photoFile(int index) => 'photo_$index';

  factory _CompletionPlan.fromSubmission(
    DeliveryProofSubmission submission, {
    required String endpoint,
    required String method,
  }) {
    final locationPolicy = submission.stop.confirmationLocation;
    return _CompletionPlan(
      stopId: submission.stop.stopId,
      endpoint: endpoint,
      method: method,
      existingProofId: submission.stop.existingProofId,
      photoSequenceStart: submission.stop.existingPhotoCount + 1,
      proofFields: {
        'route_stop': submission.stop.stopId,
        'recipient_name': submission.recipientName.trim(),
        'recipient_document': submission.recipientDocument.trim(),
        'notes': submission.notes.trim(),
      },
      photoFilenames: [for (final photo in submission.photos) photo.filename],
      completionData: {
        if (submission.itemResults.isNotEmpty)
          'item_results': submission.itemResults
              .map((result) => result.toJson())
              .toList(),
        if (locationPolicy.canRequestLocation &&
            submission.latitude != null &&
            submission.longitude != null) ...{
          locationPolicy.latitudeField: submission.latitude,
          locationPolicy.longitudeField: submission.longitude,
        },
      },
    );
  }

  factory _CompletionPlan.fromJson(Map<String, dynamic> json) {
    final proofFields = json['proof_fields'];
    final completionData = json['completion_data'];
    final photos = json['photo_filenames'];
    return _CompletionPlan(
      stopId: _asInt(json['stop_id']) ?? 0,
      endpoint: json['endpoint']?.toString() ?? '',
      method: json['method']?.toString() ?? 'POST',
      existingProofId: _asInt(json['existing_proof_id']),
      photoSequenceStart: _asInt(json['photo_sequence_start']) ?? 1,
      proofFields: proofFields is Map
          ? Map<String, dynamic>.from(proofFields)
          : const {},
      photoFilenames: photos is List
          ? photos.map((item) => item.toString()).toList()
          : const [],
      completionData: completionData is Map
          ? Map<String, dynamic>.from(completionData)
          : const {},
    );
  }

  final int stopId;
  final String endpoint;
  final String method;
  final int? existingProofId;
  final int photoSequenceStart;
  final Map<String, dynamic> proofFields;
  final List<String> photoFilenames;
  final Map<String, dynamic> completionData;

  Map<String, dynamic> toJson() => {
    'stop_id': stopId,
    'endpoint': endpoint,
    'method': method,
    'existing_proof_id': existingProofId,
    'photo_sequence_start': photoSequenceStart,
    'proof_fields': proofFields,
    'photo_filenames': photoFilenames,
    'completion_data': completionData,
  };
}
