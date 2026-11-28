import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/sync/mobile_sync.dart';
import 'package:star_tracker/features/waves/data/active_route_service.dart';
import 'package:star_tracker/features/waves/data/local_pickup_state.dart';
import 'package:star_tracker/features/waves/data/local_route_state.dart';
import 'package:star_tracker/features/waves/data/wave_service.dart';

ActiveRouteStop _stop(
  int id, {
  String status = 'planned',
  List<DeliveryContentItem> contents = const [],
}) => ActiveRouteStop(
  stopId: id,
  orderId: id * 10,
  sequence: id,
  status: status,
  orderStatus: 'out_for_delivery',
  isManual: false,
  plannedEta: null,
  orderNumber: 'PED-$id',
  customerName: 'Cliente',
  customerPhone: '',
  fullAddress: '',
  latitude: null,
  longitude: null,
  units: 1,
  weightGrams: 0,
  contents: contents,
  proofOverrides: const {},
  policy: CompletionPolicy.fromOverrides(const {}),
  existingProofId: null,
  existingPhotoCount: 0,
  hasSignature: false,
  existingRecipientName: '',
  existingRecipientDocument: '',
  existingNotes: '',
);

ActiveRoute _route({
  String status = 'started',
  int cancelled = 0,
  List<String> otherOrders = const [],
}) => ActiveRoute(
  routeId: 7,
  waveId: 3,
  routeNumber: 'R-7',
  status: status,
  path: const [],
  deliveryWaypoints: const {},
  warehouse: null,
  stops: [_stop(1), _stop(2)],
  cancelledStops: [
    for (var i = 0; i < cancelled; i++) _stop(90 + i, status: 'cancelled'),
  ],
  otherWaveOrderStatuses: otherOrders,
);

PendingSyncEvent _event(String kind, Map<String, dynamic> fields) =>
    PendingSyncEvent(
      id: kind,
      kind: kind,
      fields: fields,
      occurredAt: DateTime(2026, 11, 16, 10),
    );

PendingSyncEvent _complete(int stopId, [List<Object>? items]) =>
    _event(SyncKind.stopComplete, {'stop_id': stopId, 'items': ?items});

void main() {
  group('rota e carga no aparelho seguem a regra do servidor', () {
    test('todas entregues: rota e carga concluídas', () {
      final route = applyLocalEvents(_route(), [_complete(1), _complete(2)]);

      expect(route.stops.map((stop) => stop.status), everyElement('completed'));
      expect(
        route.stops.map((stop) => stop.orderStatus),
        everyElement('delivered'),
      );
      expect(route.status, 'completed');
      expect(route.waveStatus, 'completed');
    });

    test('uma falha: rota e carga parcialmente concluídas', () {
      final route = applyLocalEvents(_route(), [
        _complete(1),
        _event(SyncKind.stopFail, {'stop_id': 2}),
      ]);

      expect(route.stops.last.orderStatus, 'delivery_failed');
      expect(route.status, 'partially_completed');
      expect(route.waveStatus, 'partially_completed');
    });

    test('parada cancelada conta como não concluída', () {
      final route = applyLocalEvents(_route(cancelled: 1), [
        _complete(1),
        _complete(2),
      ]);
      expect(route.status, 'partially_completed');
    });

    test('pedido da carga fora da rota e não entregue: carga parcial', () {
      final route = applyLocalEvents(
        _route(otherOrders: const ['ready_for_routing']),
        [_complete(1), _complete(2)],
      );
      expect(route.status, 'completed');
      expect(route.waveStatus, 'partially_completed');
    });

    test('outra rota da carga ainda em curso: carga continua aberta '
        '(_finish_wave_if_terminal)', () {
      final route = applyLocalEvents(
        _route(otherOrders: const ['out_for_delivery', 'delivered']),
        [_complete(1), _complete(2)],
      );
      expect(route.status, 'completed');
      expect(route.waveStatus, '');
    });

    test('com parada pendente, rota segue em andamento', () {
      final route = applyLocalEvents(_route(), [_complete(1)]);
      expect(route.status, 'started');
      expect(route.waveStatus, '');
      expect(route.currentStop?.stopId, 2);
    });

    test('rota cancelada no portal continua cancelada', () {
      final route = applyLocalEvents(_route(status: 'cancelled'), [
        _complete(1),
        _complete(2),
      ]);
      expect(route.status, 'cancelled');
    });

    test('iniciar, chegar e começar a entrega', () {
      final route = applyLocalEvents(_route(status: 'released'), [
        _event(SyncKind.routeStart, {'route_id': 7}),
        _event(SyncKind.stopArrive, {'stop_id': 1}),
        _event(SyncKind.stopBegin, {'stop_id': 1}),
      ]);
      expect(route.status, 'started');
      expect(route.stops.first.status, 'delivering');
    });

    test('começar sem chegada não muda a parada (como begin_stop)', () {
      final route = applyLocalEvents(_route(), [
        _event(SyncKind.stopBegin, {'stop_id': 1}),
      ]);
      expect(route.stops.first.status, 'planned');
    });

    test('próxima entrega manda a parada para o fim', () {
      final route = applyLocalEvents(_route(), [
        _event(SyncKind.stopPostpone, {'stop_id': 1}),
      ]);
      expect(route.currentStop?.stopId, 2);
      expect(route.stops.last.stopId, 1);
    });

    test('só itens com falha: pedido falha; mistura: pedido entregue', () {
      const items = [
        DeliveryContentItem(
          id: 5,
          name: 'A',
          volumeCount: 1,
          status: 'pending',
          failureReason: '',
          failureNotes: '',
        ),
        DeliveryContentItem(
          id: 6,
          name: 'B',
          volumeCount: 1,
          status: 'pending',
          failureReason: '',
          failureNotes: '',
        ),
      ];
      final base = _route().copyWith(
        stops: [
          _stop(1, contents: items),
          _stop(2, contents: items),
        ],
      );
      final route = applyLocalEvents(base, [
        _complete(1, [
          {'id': 5, 'status': 'failed'},
          {'id': 6, 'status': 'failed'},
        ]),
        _complete(2, [
          {'id': 5, 'status': 'failed'},
          {'id': 6, 'status': 'delivered'},
        ]),
      ]);
      expect(route.stops.first.orderStatus, 'delivery_failed');
      expect(route.stops.last.orderStatus, 'delivered');
    });
  });

  group('retirada no aparelho segue a regra do servidor', () {
    Map<String, dynamic> raw() => {
      'wave_id': 3,
      'pickup_enabled': true,
      'orders': [
        {
          'order_id': 81,
          'order_number': 'PED-81',
          'codes': [
            {'code': 'PED-81-1', 'scanned_at': null},
            {'code': 'PED-81-2', 'scanned_at': null},
          ],
          'picked_up_at': null,
        },
        {
          'order_id': 82,
          'order_number': 'PED-82',
          'codes': [
            {'code': 'PED-82', 'scanned_at': '2026-11-16T10:00:00Z'},
          ],
          'picked_up_at': '2026-11-16T10:00:00Z',
        },
      ],
    };

    test('mesmas recusas e mensagens de register_pickup', () {
      expect(
        matchPickupCode(raw(), '  ').refusal,
        'Informe o código da etiqueta.',
      );
      expect(
        matchPickupCode(raw(), 'XYZ').refusal,
        'Nenhum pedido desta carga corresponde ao código XYZ.',
      );
      expect(
        matchPickupCode(raw(), 'ped-82').refusal,
        'O pedido PED-82 já havia sido retirado.',
      );
      final scanned = applyLocalPickup(raw(), 3, [
        _event(SyncKind.pickupScan, {'wave_id': 3, 'code': 'PED-81-1'}),
      ]);
      expect(
        matchPickupCode(scanned, ' ped-81-1 ').refusal,
        'A etiqueta PED-81-1 já havia sido lida.',
      );
      expect(matchPickupCode(scanned, 'ped-81-2').match?.orderId, 81);
    });

    test('tudo lido e pedido aberto no servidor: releitura é aceita', () {
      // Estado deixado por leituras simultâneas: as etiquetas constam como
      // lidas, mas o servidor não fechou o pedido. A releitura conclui.
      final stuck = raw();
      final order = (stuck['orders'] as List).first as Map<String, dynamic>;
      for (final code in order['codes'] as List) {
        (code as Map)['scanned_at'] = '2026-11-16T10:00:00Z';
      }
      expect(matchPickupCode(stuck, 'PED-81-2').match?.orderId, 81);
      final healed = applyLocalPickup(stuck, 3, [
        _event(SyncKind.pickupScan, {'wave_id': 3, 'code': 'PED-81-2'}),
      ]);
      expect(healed['is_complete'], isTrue);
    });

    test('pedido só sai da prateleira com todos os volumes lidos', () {
      final one = applyLocalPickup(raw(), 3, [
        _event(SyncKind.pickupScan, {'wave_id': 3, 'code': 'PED-81-1'}),
      ]);
      expect(one['picked_up'], 1);
      expect(one['is_complete'], isFalse);

      final both = applyLocalPickup(raw(), 3, [
        _event(SyncKind.pickupScan, {'wave_id': 3, 'code': 'PED-81-1'}),
        _event(SyncKind.pickupScan, {'wave_id': 3, 'code': 'PED-81-2'}),
      ]);
      expect(both['picked_up'], 2);
      expect(both['pending'], 0);
      expect(both['is_complete'], isTrue);
    });

    test('conferência feita no aparelho libera a parada com cópia antiga', () {
      bool blocked(List<PendingSyncEvent> events, int orderId) =>
          WaveService.parsePickupProgress(
            {...applyLocalPickup(raw(), 3, events), 'pickup_enabled': true},
            3,
          ).requiresPickup(orderId: orderId, orderStatus: 'awaiting_pickup');
      final first = _event(SyncKind.pickupScan, {
        'wave_id': 3,
        'code': 'PED-81-1',
      });
      final second = _event(SyncKind.pickupScan, {
        'wave_id': 3,
        'code': 'PED-81-2',
      });
      expect(blocked([first], 81), isTrue);
      expect(blocked([first], 82), isFalse);
      expect(blocked([first], 99), isTrue);
      expect(blocked([first, second], 81), isFalse);
    });

    test('"não vai" tira o pedido da conferência e libera a carga', () {
      final result = applyLocalPickup(raw(), 3, [
        _event(SyncKind.pickupNotGoing, {'wave_id': 3, 'order_id': 81}),
      ]);
      expect(result['total'], 1);
      expect(result['is_complete'], isTrue);
    });

    test('leituras de outra carga são ignoradas e a cópia não é alterada', () {
      final original = raw();
      final result = applyLocalPickup(original, 3, [
        _event(SyncKind.pickupScan, {'wave_id': 9, 'code': 'PED-81-1'}),
      ]);
      expect(result['picked_up'], 1);
      expect(
        ((original['orders'] as List).first as Map)['codes'],
        everyElement(containsPair('scanned_at', null)),
      );
    });
  });
}
