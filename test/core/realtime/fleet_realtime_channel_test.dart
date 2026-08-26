import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/config/app_config.dart';
import 'package:star_tracker/core/realtime/fleet_realtime_channel.dart';

void main() {
  group('FleetRealtimeEvent', () {
    test('interpreta atualizacao de rota aninhada', () {
      final event = FleetRealtimeEvent.tryParse('''
        {
          "type": "delivery_route_update",
          "data": {"id": 25, "order_ids": [81, 82]}
        }
      ''');

      expect(event, isNotNull);
      expect(event!.isRouteChange, isTrue);
      expect(event.routeId, 25);
      expect(event.data['order_ids'], [81, 82]);
    });

    test('interpreta remocao de pedido pelo id do envelope', () {
      final event = FleetRealtimeEvent.tryParse({
        'type': 'delivery_order_remove',
        'order_id': '81',
      });

      expect(event, isNotNull);
      expect(event!.isOrderChange, isTrue);
      expect(event.orderId, 81);
    });

    test('ignora mensagens invalidas', () {
      expect(FleetRealtimeEvent.tryParse('invalida'), isNull);
      expect(FleetRealtimeEvent.tryParse({'account_id': 1}), isNull);
    });
  });

  group('AppConfig.webSocketUriFor', () {
    test('usa ws no backend http local', () {
      expect(
        AppConfig.webSocketUriFor(
          'http://10.0.2.2:8000',
          '/ws/mobile/fleet/',
        ).toString(),
        'ws://10.0.2.2:8000/ws/mobile/fleet/',
      );
    });

    test('usa wss no backend https de producao', () {
      expect(
        AppConfig.webSocketUriFor(
          'https://api.exemplo.com',
          '/ws/mobile/fleet/',
        ).toString(),
        'wss://api.exemplo.com/ws/mobile/fleet/',
      );
    });

    test('bloqueia HTTP em configuracao de release', () {
      expect(
        () => AppConfig.validateBackendUrl(
          'http://api.exemplo.com',
          releaseMode: true,
        ),
        throwsStateError,
      );
    });

    test('aceita HTTPS sem credenciais embutidas', () {
      expect(
        AppConfig.validateBackendUrl(
          'https://api.exemplo.com/',
          releaseMode: true,
        ),
        'https://api.exemplo.com',
      );
      expect(
        () => AppConfig.validateBackendUrl(
          'https://usuario:senha@api.exemplo.com',
          releaseMode: true,
        ),
        throwsStateError,
      );
    });
  });
}
