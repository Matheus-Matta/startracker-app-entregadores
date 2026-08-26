import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_collection.dart';
import '../../../core/presentation/delivery_terminology.dart';

class DeliveryNotification {
  const DeliveryNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.message,
    required this.icon,
    required this.level,
    required this.url,
    required this.data,
    required this.isRead,
    required this.readAt,
    required this.createdAt,
  });

  final int id;
  final String kind;
  final String title;
  final String message;
  final String icon;
  final String level;
  final String url;
  final Map<String, dynamic> data;
  final bool isRead;
  final DateTime? readAt;
  final DateTime? createdAt;

  DeliveryNotification copyWith({bool? isRead, DateTime? readAt}) =>
      DeliveryNotification(
        id: id,
        kind: kind,
        title: title,
        message: message,
        icon: icon,
        level: level,
        url: url,
        data: data,
        isRead: isRead ?? this.isRead,
        readAt: readAt ?? this.readAt,
        createdAt: createdAt,
      );

  static DeliveryNotification? tryParse(dynamic value) {
    if (value is! Map) return null;
    final item = Map<String, dynamic>.from(value);
    final id = _asInt(item['id']);
    if (id == null) return null;
    final rawData = item['data'];
    return DeliveryNotification(
      id: id,
      kind: _boundedText(item['kind'], 64, fallback: 'general'),
      title: useDeliveryTerminology(
        _boundedText(item['title'], 160, fallback: 'Star Tracker'),
      ),
      message: useDeliveryTerminology(_boundedText(item['message'], 1000)),
      icon: _boundedText(item['icon'], 64, fallback: 'notifications'),
      level: _boundedText(item['level'], 32, fallback: 'info'),
      url: _boundedText(item['url'], 2048),
      data: rawData is Map
          ? Map<String, dynamic>.from(rawData)
          : const <String, dynamic>{},
      isRead: _asBool(item['is_read']),
      readAt: DateTime.tryParse(item['read_at']?.toString() ?? ''),
      createdAt: DateTime.tryParse(item['created_at']?.toString() ?? ''),
    );
  }
}

class NotificationServiceException implements Exception {
  const NotificationServiceException(this.message);
  final String message;
}

class NotificationService {
  const NotificationService(this.apiClient);

  final ApiClient apiClient;

  Future<List<DeliveryNotification>> getNotifications() async {
    try {
      // A central móvel mantém somente as notificações recentes. A ação de
      // marcar todas continua sendo executada pelo backend sobre o conjunto
      // completo do usuário.
      final rawItems = await apiClient.getAllPages(
        '/api/v1/notificacoes/',
        maximumPages: 5,
      );
      final notifications = rawItems
          .map(DeliveryNotification.tryParse)
          .whereType<DeliveryNotification>()
          .toList();
      notifications.sort((a, b) {
        final left = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
      return notifications;
    } on DioException catch (error) {
      throw NotificationServiceException(_errorMessage(error));
    }
  }

  Future<void> markRead(int notificationId) async {
    try {
      await apiClient.dio.post<dynamic>(
        '/api/v1/notificacoes/$notificationId/ler/',
      );
    } on DioException catch (error) {
      throw NotificationServiceException(_errorMessage(error));
    }
  }

  Future<void> markAllRead() async {
    try {
      await apiClient.dio.post<dynamic>('/api/v1/notificacoes/ler-todas/');
    } on DioException catch (error) {
      throw NotificationServiceException(_errorMessage(error));
    }
  }

  static String _errorMessage(DioException error) {
    final data = error.response?.data;
    if (data is Map) {
      final detail = data['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
    }
    return 'Não foi possível atualizar as notificações.';
  }
}

int? _asInt(dynamic value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text),
  _ => null,
};

bool _asBool(dynamic value) => switch (value) {
  true || 'true' => true,
  _ => false,
};

String _boundedText(dynamic value, int maximum, {String fallback = ''}) {
  final text = value?.toString() ?? fallback;
  return text.length <= maximum ? text : text.substring(0, maximum);
}
