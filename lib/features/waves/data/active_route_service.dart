import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/storage/session_storage.dart';

class ActiveRoute {
  const ActiveRoute({
    required this.routeId,
    required this.waveId,
    required this.routeNumber,
    required this.status,
    required this.path,
    required this.warehouse,
    required this.stops,
  });

  final int routeId;
  final int waveId;
  final String routeNumber;
  final String status;
  final List<RouteCoordinate> path;
  final RoutePlace? warehouse;
  final List<ActiveRouteStop> stops;

  ActiveRouteStop? get currentStop {
    const working = {'approaching', 'arrived', 'delivering'};
    for (final stop in stops) {
      if (working.contains(stop.status)) return stop;
    }
    for (final stop in stops) {
      if (!stop.isTerminal) return stop;
    }
    return null;
  }
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
  });

  final int stopId;
  final int orderId;
  final int sequence;
  final String status;
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

  bool get isTerminal =>
      const {'completed', 'failed', 'skipped', 'cancelled'}.contains(status);

  ActiveRouteStop withPolicy(CompletionPolicy nextPolicy) => ActiveRouteStop(
    stopId: stopId,
    orderId: orderId,
    sequence: sequence,
    status: status,
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

class ActiveRouteException implements Exception {
  const ActiveRouteException(this.message);
  final String message;
}

class ActiveRouteService {
  const ActiveRouteService(
    this.apiClient, {
    this.storage = const SessionStorage(),
  });

  final ApiClient apiClient;
  final SessionStorage storage;

  static const openFreeMapStyle =
      'https://tiles.openfreemap.org/styles/positron';

  Future<String> getMapStyle() async {
    Map<String, dynamic> style;
    try {
      final openMapResponse = await Dio().get<dynamic>(openFreeMapStyle);
      final rawStyle = openMapResponse.data;
      style = rawStyle is String
          ? _asMap(jsonDecode(rawStyle))
          : _asMap(rawStyle);
      if (style.isEmpty) return openFreeMapStyle;
    } catch (_) {
      return openFreeMapStyle;
    }

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
      if (!available || token.isEmpty) return jsonEncode(style);

      final sources = style['sources'] is Map
          ? Map<String, dynamic>.from(style['sources'] as Map)
          : <String, dynamic>{};
      sources['startracker-mapbox'] = {
        'type': 'raster',
        'tiles': [
          'https://api.mapbox.com/styles/v1/mapbox/streets-v12/tiles/512/{z}/{x}/{y}@2x?access_token=${Uri.encodeQueryComponent(token)}',
        ],
        'tileSize': 512,
        'attribution': '© Mapbox © OpenStreetMap',
      };
      style['sources'] = sources;

      final layers = style['layers'] is List
          ? List<dynamic>.from(style['layers'] as List)
          : <dynamic>[];
      layers.add({
        'id': 'startracker-mapbox-primary',
        'type': 'raster',
        'source': 'startracker-mapbox',
        'minzoom': 0,
        'maxzoom': 22,
      });
      style['layers'] = layers;
      return jsonEncode(style);
    } catch (_) {
      return jsonEncode(style);
    }
  }

  Future<ActiveRouteStop> refreshCompletionPolicy(ActiveRouteStop stop) async {
    final configuration = await _deliveryConfiguration(refresh: true);
    return stop.withPolicy(
      CompletionPolicy.fromConfiguration(
        configuration,
        overrides: stop.proofOverrides,
      ),
    );
  }

  Future<ActiveRoute> getRoute(int routeId) async {
    try {
      final results = await Future.wait<dynamic>([
        _deliveryConfiguration(),
        apiClient.dio.get<dynamic>('/api/v1/delivery/rotas/$routeId/'),
        _getAll('/api/v1/delivery/paradas/'),
        _getAll('/api/v1/delivery/pedidos/'),
        _getAllOptional('/api/v1/delivery/armazens/'),
        _getAll('/api/v1/delivery/comprovantes/'),
        _getAll('/api/v1/delivery/fotos-comprovante/'),
      ]);
      final deliveryConfig = results[0] as Map<String, dynamic>;
      final routeResponse = results[1] as Response<dynamic>;
      final route = _asMap(routeResponse.data);
      final stops = (results[2] as List<Map<String, dynamic>>)
          .where((item) => _asInt(item['route']) == routeId)
          .toList();
      final orders = {
        for (final item in results[3] as List<Map<String, dynamic>>)
          if (_asInt(item['id']) case final int id) id: item,
      };
      final warehouses = {
        for (final item in results[4] as List<Map<String, dynamic>>)
          if (_asInt(item['id']) case final int id) id: item,
      };
      final proofs = {
        for (final item in results[5] as List<Map<String, dynamic>>)
          if (_asInt(item['route_stop']) case final int stopId) stopId: item,
      };
      final photoCounts = <int, int>{};
      for (final photo in results[6] as List<Map<String, dynamic>>) {
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
          ),
        );
      }
      activeStops.sort((a, b) => a.sequence.compareTo(b.sequence));
      final path = _parsePath(route['path_geometry']);
      final firstOrder = activeStops.isEmpty
          ? null
          : orders[activeStops.first.orderId];
      final warehouseData = warehouses[_asInt(firstOrder?['warehouse'])];
      final warehouseLat = _asDouble(warehouseData?['lat']);
      final warehouseLon = _asDouble(warehouseData?['lon']);
      final warehouseCoordinate = warehouseLat != null && warehouseLon != null
          ? RouteCoordinate(warehouseLat, warehouseLon)
          : null;

      return ActiveRoute(
        routeId: _asInt(route['id']) ?? routeId,
        waveId: _asInt(route['wave']) ?? 0,
        routeNumber: route['route_number']?.toString() ?? 'Rota #$routeId',
        status: route['status']?.toString() ?? '',
        path: path,
        warehouse: warehouseCoordinate == null
            ? null
            : RoutePlace(
                name: warehouseData?['name']?.toString() ?? 'Armazém',
                coordinate: warehouseCoordinate,
              ),
        stops: activeStops,
      );
    } on DioException catch (error) {
      throw ActiveRouteException(_errorMessage(error));
    }
  }

  Future<void> arrive(int stopId) => _stopAction(stopId, 'arrive');

  Future<void> begin(int stopId) => _stopAction(stopId, 'begin');

  Future<void> startRoute(int routeId) async {
    try {
      await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/rotas/$routeId/start/',
      );
    } on DioException catch (error) {
      throw ActiveRouteException(_errorMessage(error));
    }
  }

  Future<void> fail({
    required int stopId,
    required String reason,
    required String notes,
    double? latitude,
    double? longitude,
  }) async {
    try {
      await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/paradas/$stopId/fail/',
        data: {
          'reason': reason,
          'notes': notes,
          'lat': ?latitude,
          'lon': ?longitude,
        },
      );
    } on DioException catch (error) {
      throw ActiveRouteException(_errorMessage(error));
    }
  }

  Future<void> complete(DeliveryProofSubmission submission) async {
    try {
      final proofData = <String, dynamic>{
        // items e completed_at são resultados geridos pelo complete/.
        // Nunca devem fazer parte do multipart do comprovante.
        'route_stop': submission.stop.stopId,
        'recipient_name': submission.recipientName.trim(),
        'recipient_document': submission.recipientDocument.trim(),
        'notes': submission.notes.trim(),
        if (submission.latitude != null) 'lat': submission.latitude,
        if (submission.longitude != null) 'lon': submission.longitude,
        if (submission.signatureBytes != null)
          'signature_file': MultipartFile.fromBytes(
            submission.signatureBytes!,
            filename: 'assinatura.png',
          ),
      };

      int proofId;
      if (submission.stop.existingProofId case final int existingId) {
        final response = await apiClient.dio.patch<dynamic>(
          '/api/v1/delivery/comprovantes/$existingId/',
          data: FormData.fromMap(proofData),
        );
        proofId = _asInt(_asMap(response.data)['id']) ?? existingId;
      } else {
        final response = await apiClient.dio.post<dynamic>(
          '/api/v1/delivery/comprovantes/',
          data: FormData.fromMap(proofData),
        );
        final createdId = _asInt(_asMap(response.data)['id']);
        if (createdId == null) {
          throw const ActiveRouteException(
            'O servidor não retornou o comprovante criado.',
          );
        }
        proofId = createdId;
      }

      var sequence = submission.stop.existingPhotoCount + 1;
      for (final photo in submission.photos) {
        await apiClient.dio.post<dynamic>(
          '/api/v1/delivery/fotos-comprovante/',
          data: FormData.fromMap({
            'delivery_proof': proofId,
            'sequence': sequence++,
            'file': MultipartFile.fromBytes(
              photo.bytes,
              filename: photo.filename,
            ),
          }),
        );
      }

      await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/paradas/${submission.stop.stopId}/complete/',
        data: submission.itemResults.isEmpty
            ? null
            : {
                'items': submission.itemResults
                    .map((result) => result.toJson())
                    .toList(),
              },
      );
    } on ActiveRouteException {
      rethrow;
    } on DioException catch (error) {
      throw ActiveRouteException(_errorMessage(error));
    }
  }

  Future<void> _stopAction(int stopId, String action) async {
    try {
      await apiClient.dio.post<dynamic>(
        '/api/v1/delivery/paradas/$stopId/$action/',
      );
    } on DioException catch (error) {
      throw ActiveRouteException(_errorMessage(error));
    }
  }

  Future<Map<String, dynamic>> _deliveryConfiguration({
    bool refresh = false,
  }) async {
    final cached = await storage.readDeliveryConfig();
    if (!refresh) return cached;

    try {
      final response = await apiClient.dio.get<dynamic>(
        '/api/v1/auth/entregadores/configuracao/',
      );
      final config = _configurationFromResponse(response.data);
      if (config.isNotEmpty) {
        await storage.saveDeliveryConfig(config);
        return config;
      }
    } on DioException {
      // Login/cache continua sendo uma fonte segura quando a consulta falhar.
    }
    return cached;
  }

  static Map<String, dynamic> _configurationFromResponse(dynamic data) {
    dynamic raw = data;
    if (data is Map) {
      raw = data['delivery_config'] ?? data['config'] ?? data;
      if (data['results'] is List && (data['results'] as List).isNotEmpty) {
        raw = (data['results'] as List).first;
      }
    }
    if (raw is! Map) return const {};
    const keys = {
      'version',
      'require_photo',
      'minimum_photos',
      'maximum_photos',
      'require_signature',
      'require_recipient_name',
      'require_document',
      'require_note_on_failure',
      'capture_timestamp',
      'pickup_enabled',
      'pickup_barcode_source',
    };
    final result = Map<String, dynamic>.from(raw);
    result.removeWhere((key, _) => !keys.contains(key));
    return result;
  }

  Future<List<Map<String, dynamic>>> _getAll(String path) async {
    final items = <Map<String, dynamic>>[];
    var page = 1;
    while (page <= 100) {
      final response = await apiClient.dio.get<dynamic>(
        path,
        queryParameters: {'page': page},
      );
      final data = response.data;
      final raw = data is Map ? data['results'] : data;
      if (raw is List) {
        items.addAll(raw.whereType<Map>().map(_asMap));
      }
      if (data is! Map || data['next'] == null) break;
      page++;
    }
    return items;
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
    if (data is List && data.isNotEmpty) return data.first.toString();
    if (data is Map) {
      final detail = data['detail'] ?? data['non_field_errors'];
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) return detail.first.toString();
      for (final value in data.values) {
        if (value is List && value.isNotEmpty) return value.first.toString();
        if (value is String && value.isNotEmpty) return value;
      }
    }
    return 'Não foi possível concluir a operação. Tente novamente.';
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
