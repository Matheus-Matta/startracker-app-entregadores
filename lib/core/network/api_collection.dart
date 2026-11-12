import 'package:dio/dio.dart';

import 'api_client.dart';

extension ApiCollection on ApiClient {
  Future<List<Map<String, dynamic>>> getAllPages(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    int maximumPages = 100,
    // O backend devolve 50 por padrão e aceita até 100: páginas maiores
    // cortam pela metade as idas e voltas, que no 4G custam mais que os bytes.
    int pageSize = 100,
  }) async {
    final items = <Map<String, dynamic>>[];
    for (var page = 1; page <= maximumPages; page++) {
      final response = await dio.get<dynamic>(
        path,
        queryParameters: {
          ...?queryParameters,
          'page': page,
          'page_size': pageSize,
        },
        options: options,
      );
      items.addAll(collectionItems(response.data));
      final data = response.data;
      if (data is! Map || data['next'] == null) break;
    }
    return items;
  }
}

List<Map<String, dynamic>> collectionItems(dynamic data) {
  final rawItems = data is Map ? data['results'] : data;
  if (rawItems is! List) return const [];
  return rawItems
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}
