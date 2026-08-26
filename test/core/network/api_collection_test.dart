import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:star_tracker/core/network/api_client.dart';
import 'package:star_tracker/core/network/api_collection.dart';
import 'package:star_tracker/core/storage/session_storage.dart';
import 'package:star_tracker/features/orders/data/order_service.dart';

void main() {
  late _CountingAdapter adapter;
  late ApiClient apiClient;

  setUp(() {
    adapter = _CountingAdapter();
    apiClient = ApiClient(
      baseUrl: 'https://api.example.test',
      storage: const _MemorySessionStorage(),
    );
    apiClient.dio.httpClientAdapter = adapter;
  });

  test('pagina colecoes ate next ser nulo', () async {
    final items = await apiClient.getAllPages('/orders/');

    expect(items.map((item) => item['id']), [1, 2]);
    expect(adapter.requests, 2);
  });

  test(
    'OrderService reutiliza cache e permite invalidacao explicita',
    () async {
      final service = OrderService(apiClient);

      await service.getOrders(page: 1);
      await service.getOrders(page: 1);
      expect(adapter.requests, 1);

      service.invalidateCache();
      await service.getOrders(page: 1, refresh: true);
      expect(adapter.requests, 2);
    },
  );
}

class _MemorySessionStorage extends SessionStorage {
  const _MemorySessionStorage();

  @override
  Future<String?> readToken() async => null;
}

class _CountingAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final page = int.tryParse(options.queryParameters['page'].toString()) ?? 1;
    final id = page == 1 ? 1 : 2;
    return ResponseBody.fromString(
      jsonEncode({
        'count': 2,
        'next': page == 1 ? 'https://api.example.test/orders/?page=2' : null,
        'previous': page == 1 ? null : 'https://api.example.test/orders/',
        'results': [
          {
            'id': id,
            'order_number': 'PED-$id',
            'customer_name': 'Cliente $id',
            'status': 'released',
            'created_at': '2026-08-24T12:00:00Z',
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
