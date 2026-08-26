import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/features/waves/data/pickup_label_scope.dart';
import 'package:star_tracker/features/waves/data/wave_service.dart';

void main() {
  group('WaveService.displayStatus', () {
    test(
      'prioriza rota iniciada mesmo quando o status da wave esta defasado',
      () {
        expect(WaveService.displayStatus('ready', 'started'), 'started');
      },
    );

    test('mantem o status proprio da wave antes da rota ser iniciada', () {
      expect(WaveService.displayStatus('ready', 'released'), 'ready');
    });

    test('usa o status da rota durante a operacao normal', () {
      expect(WaveService.displayStatus('released', 'started'), 'started');
    });
  });

  group('WaveService.parsePickupProgress', () {
    test('interpreta a conferencia e os codigos por volume', () {
      final progress = WaveService.parsePickupProgress({
        'wave_id': 10,
        'pickup_enabled': true,
        'barcode_source': 'order_number',
        'total': 2,
        'picked_up': 0,
        'pending': 2,
        'is_complete': false,
        'orders': [
          {
            'order_id': 81,
            'order_number': 'PED-2026-001',
            'customer': 'Cliente Exemplo',
            'codes': [
              {
                'code': 'PED-2026-001-1',
                'scanned_at': '2026-08-22T09:14:00-03:00',
              },
              {'code': 'PED-2026-001-2', 'scanned_at': null},
            ],
            'picked_up_at': null,
          },
          {
            'order_id': 82,
            'order_number': 'PED-2026-002',
            'customer': 'Outro cliente',
            'codes': [
              {'code': 'PED-2026-002', 'scanned_at': null},
            ],
            'picked_up_at': null,
          },
        ],
      }, 99);

      expect(progress.waveId, 10);
      expect(progress.total, 2);
      expect(progress.totalVolumes, 3);
      expect(progress.scannedVolumes, 1);
      expect(progress.pendingVolumes, 2);
      expect(progress.orders.first.totalVolumes, 2);
      expect(progress.orders.first.scannedVolumes, 1);
      expect(progress.orders.first.isPickedUp, isFalse);
      expect(progress.orders.first.codes.last.code, 'PED-2026-001-2');
      expect(progress.orders.first.codes.last.isScanned, isFalse);
    });

    test('continua aceitando o payload antigo com code unico', () {
      final progress = WaveService.parsePickupProgress({
        'pickup_enabled': true,
        'orders': [
          {
            'order_id': 81,
            'order_number': 'PED-81',
            'code': 'PED-81',
            'picked_up_at': '2026-08-22T09:14:00-03:00',
          },
        ],
      }, 10);

      expect(progress.totalVolumes, 1);
      expect(progress.scannedVolumes, 1);
      expect(progress.orders.single.codes.single.code, 'PED-81');
      expect(progress.orders.single.codes.single.isScanned, isTrue);
    });

    test('agrupa os volumes por item quando o total confere', () {
      final progress = WaveService.parsePickupProgress({
        'pickup_enabled': true,
        'orders': [
          {
            'order_id': 81,
            'order_number': 'PED-81',
            'codes': [
              {'code': 'PED-81-1', 'scanned_at': null},
              {'code': 'PED-81-2', 'scanned_at': null},
              {'code': 'PED-81-3', 'scanned_at': null},
            ],
            'items': [
              {
                'id': 15,
                'name': 'Guarda-roupa',
                'volumes': [
                  {'id': 31},
                  {'id': 32},
                ],
              },
              {
                'id': 16,
                'name': 'Colchão',
                'volumes': [
                  {'id': 33},
                ],
              },
            ],
          },
        ],
      }, 10);

      final items = progress.orders.single.items;
      expect(items.length, 2);
      expect(items.first.volumeCount, 2);
      expect(items.first.covers(1), isTrue);
      expect(items.last.firstVolumeIndex, 2);
    });

    test('ignora a itemizacao quando ela nao cobre todas as etiquetas', () {
      final items = WaveService.parsePickupItems([
        {
          'id': 15,
          'volumes': [
            {'id': 31},
          ],
        },
      ], 3);

      expect(items, isEmpty);
    });
  });

  group('PickupOrder.codesForScan', () {
    PickupOrder buildOrder({DateTime? secondVolumeScannedAt}) => PickupOrder(
      orderId: 81,
      orderNumber: 'PED-81',
      customer: 'Cliente',
      pickedUpAt: null,
      codes: [
        const PickupCode(code: 'PED-81-1', scannedAt: null),
        PickupCode(code: 'PED-81-2', scannedAt: secondVolumeScannedAt),
        const PickupCode(code: 'PED-81-3', scannedAt: null),
      ],
      items: const [
        PickupItemGroup(
          id: 15,
          name: 'Guarda-roupa',
          firstVolumeIndex: 0,
          volumeCount: 2,
        ),
        PickupItemGroup(
          id: 16,
          name: 'Colchão',
          firstVolumeIndex: 2,
          volumeCount: 1,
        ),
      ],
    );

    test('no escopo de volume confere so a etiqueta lida', () {
      expect(buildOrder().codesForScan('ped-81-1 ', PickupLabelScope.volume), [
        'PED-81-1',
      ]);
    });

    test('no escopo de item confere os volumes daquele item', () {
      expect(buildOrder().codesForScan('PED-81-1', PickupLabelScope.item), [
        'PED-81-1',
        'PED-81-2',
      ]);
    });

    test('no escopo de pedido confere todos os volumes pendentes', () {
      expect(buildOrder().codesForScan('PED-81-1', PickupLabelScope.order), [
        'PED-81-1',
        'PED-81-2',
        'PED-81-3',
      ]);
    });

    test('nao reenvia volume ja conferido', () {
      final order = buildOrder(secondVolumeScannedAt: DateTime(2026, 8, 22));
      expect(order.codesForScan('PED-81-1', PickupLabelScope.order), [
        'PED-81-1',
        'PED-81-3',
      ]);
    });

    test('sem itemizacao o escopo de item cai no volume lido', () {
      const order = PickupOrder(
        orderId: 82,
        orderNumber: 'PED-82',
        customer: 'Cliente',
        pickedUpAt: null,
        codes: [
          PickupCode(code: 'PED-82-1', scannedAt: null),
          PickupCode(code: 'PED-82-2', scannedAt: null),
        ],
      );

      expect(order.codesForScan('PED-82-1', PickupLabelScope.item), [
        'PED-82-1',
      ]);
    });

    test('codigo desconhecido segue para a API como veio', () {
      expect(buildOrder().codesForScan(' OUTRO-1 ', PickupLabelScope.order), [
        'OUTRO-1',
      ]);
    });
  });
}
