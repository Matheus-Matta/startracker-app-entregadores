import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/realtime/notification_realtime_channel.dart';
import 'package:star_tracker/features/notifications/data/notification_service.dart';

void main() {
  test('interpreta notificacao pessoal da API', () {
    final notification = DeliveryNotification.tryParse({
      'id': 15,
      'kind': 'wave_assigned',
      'title': 'Uma wave foi atribuída a você',
      'message': 'A wave #42 está disponível para atendimento.',
      'icon': 'local_shipping',
      'level': 'info',
      'url': '/app/minhas-entregas/',
      'data': {'wave_id': 42},
      'is_read': false,
      'read_at': null,
      'created_at': '2026-08-19T22:10:00-03:00',
    });

    expect(notification, isNotNull);
    expect(notification!.id, 15);
    expect(notification.kind, 'wave_assigned');
    expect(notification.title, 'Uma carga foi atribuída a você');
    expect(
      notification.message,
      'A carga #42 está disponível para atendimento.',
    );
    expect(notification.data['wave_id'], 42);
    expect(notification.isRead, isFalse);
    expect(notification.createdAt, isNotNull);
  });

  test('interpreta envelope websocket com notification aninhada', () {
    final notification = NotificationRealtimeChannel.tryParseMessage('''
      {
        "type": "notification",
        "data": {
          "notification": {
            "id": 16,
            "kind": "general",
            "title": "Aviso",
            "message": "Operação atualizada",
            "is_read": false
          }
        }
      }
    ''');

    expect(notification, isNotNull);
    expect(notification!.id, 16);
    expect(notification.title, 'Aviso');
  });

  test('ignora mensagens websocket que nao sao notificacoes', () {
    expect(
      NotificationRealtimeChannel.tryParseMessage(
        '{"type":"connected","account_id":1}',
      ),
      isNull,
    );
  });
}
