import 'package:dio/dio.dart';

import 'api_client.dart';
import 'api_failure.dart';

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
      requirePage(response);
      items.addAll(collectionItems(response.data));
      final data = response.data;
      if (data is! Map || data['next'] == null) break;
    }
    return items;
  }
}

extension RecentApiCollection on ApiClient {
  /// Registros mais novos primeiro (`ordering=-id`), até [maximumItems].
  ///
  /// Ler o histórico inteiro deixava a tela de cargas mais lenta a cada mês
  /// (uma ida e volta no 4G por página de 100). Servidor que ainda não
  /// ordene devolve ids crescentes: nesse caso lê tudo, como antes, para não
  /// esconder justamente os registros de hoje.
  Future<List<Map<String, dynamic>>> getRecentPages(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    int maximumItems = 200,
    int pageSize = 100,
  }) async {
    final items = <Map<String, dynamic>>[];
    var newestFirst = true;
    for (var page = 1; page <= 100; page++) {
      final response = await dio.get<dynamic>(
        path,
        queryParameters: {
          ...?queryParameters,
          'ordering': '-id',
          'page': page,
          'page_size': pageSize,
        },
        options: options,
      );
      requirePage(response);
      final pageItems = collectionItems(response.data);
      if (page == 1 && pageItems.length > 1) {
        final first = _id(pageItems.first);
        final last = _id(pageItems.last);
        newestFirst = first == null || last == null || first > last;
      }
      items.addAll(pageItems);
      final data = response.data;
      if (data is! Map || data['next'] == null) break;
      if (newestFirst && items.length >= maximumItems) break;
    }
    return items;
  }

  static int? _id(Map<String, dynamic> item) => switch (item['id']) {
    int value => value,
    String value => int.tryParse(value),
    _ => null,
  };
}

List<Map<String, dynamic>> collectionItems(dynamic data) {
  final rawItems = data is Map ? data['results'] : data;
  if (rawItems is! List) return const [];
  return rawItems
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

/// Uma página da API é uma lista ou `{"results": [...]}`. Qualquer outra
/// coisa (objeto de erro com 200, HTML) virava uma rota vazia sem aviso:
/// o entregador via "nenhuma entrega" sem saber que a leitura falhou.
void requirePage(Response<dynamic> response) {
  final data = response.data;
  if (data is List || (data is Map && data['results'] is List)) return;
  final shape = data is Map
      ? 'objeto sem "results" (${data.keys.take(4).join(', ')})'
      : data.runtimeType.toString();
  throw DioException(
    requestOptions: response.requestOptions,
    response: response,
    type: DioExceptionType.badResponse,
    error: UnexpectedResponseFormat('página inválida: $shape'),
  );
}
