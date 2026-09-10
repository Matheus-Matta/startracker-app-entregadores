import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';

void main() {
  test('currentStop respeita a sequencia depois de adiar uma parada', () {
    final route = ActiveRoute(
      routeId: 1,
      waveId: 1,
      routeNumber: 'Rota 1',
      status: 'started',
      path: const [],
      deliveryWaypoints: const {},
      warehouse: null,
      stops: [
        _stop(id: 3, sequence: 2, status: 'planned'),
        _stop(id: 2, sequence: 3, status: 'approaching'),
      ],
    );

    expect(route.currentStop?.stopId, 3);
  });

  test('le o armazem de origem nos planned_waypoints da rota', () {
    final warehouse = ActiveRouteService.parseWarehouseWaypoint(const [
      {
        'kind': 'pickup',
        'warehouse_id': 1,
        'name': 'Centro de Distribuicao',
        'location': [-43.0027, -22.8298],
      },
    ]);

    expect(warehouse?.name, 'Centro de Distribuicao');
    expect(warehouse?.coordinate.latitude, -22.8298);
    expect(warehouse?.coordinate.longitude, -43.0027);
  });

  test('remove da rota ativa a parada cancelada por transferencia', () async {
    final client = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: const _EmptyStorage(),
    );
    client.dio.httpClientAdapter = _CancelledStopAdapter();
    final service = ActiveRouteService(client, storage: const _EmptyStorage());

    final route = await service.getRoute(20);

    expect(route.stops, isEmpty);
    expect(route.currentStop, isNull);
  });
}

ActiveRouteStop _stop({
  required int id,
  required int sequence,
  required String status,
}) => ActiveRouteStop(
  stopId: id,
  orderId: id,
  sequence: sequence,
  status: status,
  orderStatus: 'out_for_delivery',
  isManual: false,
  plannedEta: null,
  orderNumber: 'PED-$id',
  customerName: 'Cliente $id',
  customerPhone: '',
  fullAddress: '',
  latitude: null,
  longitude: null,
  units: 1,
  weightGrams: 0,
  contents: const [],
  proofOverrides: const {},
  policy: CompletionPolicy.fromOverrides(const {}),
  existingProofId: null,
  existingPhotoCount: 0,
  hasSignature: false,
  existingRecipientName: '',
  existingRecipientDocument: '',
  existingNotes: '',
);

class _EmptyStorage extends SessionStorage {
  const _EmptyStorage();

  @override
  Future<String?> readToken() async => null;

  @override
  Future<Map<String, dynamic>> readDeliveryConfig() async => const {};
}

class _CancelledStopAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = switch (options.path) {
      '/api/v1/delivery/rotas/20/' => {
        'id': 20,
        'wave': 10,
        'route_number': 'Rota 20',
        'status': 'started',
        'path_geometry': <dynamic>[],
        'planned_waypoints': <dynamic>[],
      },
      '/api/v1/delivery/paradas/' => {
        'results': [
          {
            'id': 30,
            'route': 20,
            'order': 81,
            'sequence': 1,
            'status': 'cancelled',
          },
        ],
        'next': null,
      },
      _ => {'results': <dynamic>[], 'next': null},
    };
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
