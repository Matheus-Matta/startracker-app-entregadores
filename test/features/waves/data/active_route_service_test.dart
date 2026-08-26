import 'package:flutter_test/flutter_test.dart';
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
