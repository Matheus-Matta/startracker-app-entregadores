import 'dart:async';
import 'dart:convert';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_collection.dart';
import '../../../core/network/offline_deadline.dart';
import '../../../core/network/paged_result.dart';
import '../../../core/sync/mobile_sync.dart';
import '../../waves/data/route_snapshot_store.dart';

class OrderListItem {
  const OrderListItem({
    required this.id,
    required this.number,
    required this.customerName,
    required this.address,
    required this.city,
    required this.state,
    required this.status,
    required this.units,
    required this.weightGrams,
    required this.priority,
    required this.createdAt,
  });

  final int id;
  final String number;
  final String customerName;
  final String address;
  final String city;
  final String state;
  final String status;
  final int units;
  final int weightGrams;
  final int priority;
  final DateTime? createdAt;
}

class OrderDetails {
  const OrderDetails({
    required this.id,
    required this.number,
    required this.externalSource,
    required this.externalId,
    required this.customerName,
    required this.customerPhone,
    required this.warehouseId,
    required this.address,
    required this.addressNumber,
    required this.addressComplement,
    required this.neighborhood,
    required this.city,
    required this.state,
    required this.postalCode,
    required this.latitude,
    required this.longitude,
    required this.volumeCubicCentimeters,
    required this.weightGrams,
    required this.units,
    required this.priority,
    required this.effectivePriority,
    required this.skills,
    required this.serviceDurationSeconds,
    required this.deliveryWindowStart,
    required this.deliveryWindowEnd,
    required this.readyAt,
    required this.promisedAt,
    required this.status,
    required this.unassignedReason,
    required this.proofOverrides,
    required this.notes,
    required this.paymentMethod,
    required this.paymentValue,
    required this.splitFromId,
    required this.createdAt,
    required this.updatedAt,
    required this.items,
  });

  final int id;
  final String number;
  final String externalSource;
  final String externalId;
  final String customerName;
  final String customerPhone;
  final int? warehouseId;
  final String address;
  final String addressNumber;
  final String addressComplement;
  final String neighborhood;
  final String city;
  final String state;
  final String postalCode;
  final double? latitude;
  final double? longitude;
  final int volumeCubicCentimeters;
  final int weightGrams;
  final int units;
  final int priority;
  final int effectivePriority;
  final List<String> skills;
  final int serviceDurationSeconds;
  final DateTime? deliveryWindowStart;
  final DateTime? deliveryWindowEnd;
  final DateTime? readyAt;
  final DateTime? promisedAt;
  final String status;
  final String unassignedReason;
  final Map<String, dynamic> proofOverrides;

  /// Observacao livre do pedido, exibida ao entregador.
  final String notes;

  /// `cash`, `card`, `pix`, `to_arrange` ou vazio quando nao informado.
  final String paymentMethod;
  final double? paymentValue;

  /// Pedido de origem quando esta nota nasceu de um desmembro.
  final int? splitFromId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<OrderItemDetails> items;

  bool get hasPayment => paymentMethod.isNotEmpty || paymentValue != null;

  String get fullAddress => [
    [address, addressNumber].where((part) => part.isNotEmpty).join(', '),
    addressComplement,
    neighborhood,
    [city, state].where((part) => part.isNotEmpty).join('/'),
    postalCode,
  ].where((part) => part.isNotEmpty).join(' · ');
}

class OrderItemDetails {
  const OrderItemDetails({
    required this.id,
    required this.name,
    required this.volumes,
    required this.status,
    required this.failureReason,
    required this.failureNotes,
  });

  final int id;
  final String name;
  final List<OrderVolumeDetails> volumes;
  final String status;
  final String failureReason;
  final String failureNotes;
}

class OrderVolumeDetails {
  const OrderVolumeDetails({
    required this.id,
    required this.lengthCentimeters,
    required this.widthCentimeters,
    required this.heightCentimeters,
    required this.weightGrams,
  });

  final int id;
  final double lengthCentimeters;
  final double widthCentimeters;
  final double heightCentimeters;
  final int weightGrams;
}

class _CachedOrderPage {
  const _CachedOrderPage(this.createdAt, this.result);

  final DateTime createdAt;
  final PagedResult<OrderListItem> result;
}

class OrderService {
  OrderService(
    this.apiClient, {
    this.sync,
    RouteSnapshotStore? detailStore,
    RouteSnapshotStore? pageStore,
    RouteSnapshotStore? routeStore,
  }) : _routeStore = routeStore ?? RouteSnapshotStore(),
       _detailStore =
           detailStore ?? RouteSnapshotStore(folder: 'orders', prefix: 'order'),
       _pageStore =
           pageStore ??
           RouteSnapshotStore(folder: 'order_pages', prefix: 'page');

  final ApiClient apiClient;

  /// Baixas/falhas feitas no aparelho: a aba Pedidos mostra o mesmo status
  /// que o mapa e a carga, sem esperar a sincronização.
  final MobileSync? sync;
  final RouteSnapshotStore _detailStore;
  final RouteSnapshotStore _pageStore;

  /// Cópias das rotas (as mesmas do mapa): trazem os pedidos completos.
  final RouteSnapshotStore _routeStore;
  static const _cacheDuration = Duration(seconds: 30);
  List<Map<String, dynamic>>? _cachedOrders;
  DateTime? _cacheCreatedAt;

  /// Início da leitura que gerou [_cachedOrders] (ver MobileSync.localEvents):
  /// com a hora do fim, uma baixa confirmada durante o download ficava fora
  /// da sobreposição e o pedido "voltava" a Em entrega.
  DateTime? _cacheReadAt;
  DateTime? _loadOperationStartedAt;
  Future<List<Map<String, dynamic>>>? _loadOperation;
  final Map<String, _CachedOrderPage> _pageCache = {};
  final Map<String, Future<PagedResult<OrderListItem>>> _pageOperations = {};
  final Map<String, DateTime> _pageOperationStartedAt = {};
  final Map<String, int> _pageOperationGenerations = {};
  int? _loadOperationGeneration;
  String? _loadOperationStatus;
  String? _cachedOrdersStatus;
  int _cacheGeneration = 0;

  Future<PagedResult<OrderListItem>> getOrders({
    required int page,
    String search = '',
    String status = '',
    bool refresh = false,
  }) async {
    final query = search.trim().toLowerCase();
    if (query.isEmpty) {
      // Sem texto, o filtro de status é feito pelo servidor, página a página.
      // Antes, escolher um status baixava todos os pedidos da conta.
      final (result, fetchedAt) = await _getOrderPage(
        page,
        refresh: refresh,
        status: status,
      );
      return _withLocalStatuses(result, fetchedAt);
    }

    // A API não tem busca por texto; a busca local baixa só o status pedido.
    const pageSize = 20;
    final (rawItems, readAt) = await _getOrders(
      refresh: refresh,
      status: status,
    );
    final items = _parseItems(rawItems, query: query, status: status);

    final start = (page - 1) * pageSize;
    final pageItems = start >= items.length
        ? const <OrderListItem>[]
        : items.sublist(
            start,
            start + pageSize < items.length ? start + pageSize : items.length,
          );

    return _withLocalStatuses(
      PagedResult(
        items: pageItems,
        count: items.length,
        page: page,
        hasNext: start + pageSize < items.length,
        hasPrevious: page > 1,
      ),
      readAt,
    );
  }

  /// Status que o aparelho já sabe e o servidor (ou a cópia) ainda não.
  Map<int, String> _localStatuses(DateTime? fetchedAt) {
    final statuses = <int, String>{};
    for (final event in sync?.localEvents(fetchedAt: fetchedAt) ?? const []) {
      final orderId = event.intField('order_id');
      final status = event.fields['local_order_status']?.toString();
      if (orderId != null && status != null && status.isNotEmpty) {
        statuses[orderId] = status;
      }
    }
    return statuses;
  }

  PagedResult<OrderListItem> _withLocalStatuses(
    PagedResult<OrderListItem> result,
    DateTime? fetchedAt,
  ) {
    final local = _localStatuses(fetchedAt);
    if (local.isEmpty) return result;
    return PagedResult(
      items: [
        for (final item in result.items)
          local[item.id] == null || local[item.id] == item.status
              ? item
              : OrderListItem(
                  id: item.id,
                  number: item.number,
                  customerName: item.customerName,
                  address: item.address,
                  city: item.city,
                  state: item.state,
                  status: local[item.id]!,
                  units: item.units,
                  weightGrams: item.weightGrams,
                  priority: item.priority,
                  createdAt: item.createdAt,
                ),
      ],
      count: result.count,
      page: result.page,
      hasNext: result.hasNext,
      hasPrevious: result.hasPrevious,
    );
  }

  List<OrderListItem> _parseItems(
    List<Map<String, dynamic>> rawItems, {
    String query = '',
    String status = '',
  }) {
    final items = <OrderListItem>[];

    for (final item in rawItems) {
      final id = _asInt(item['id']);
      if (id == null) continue;
      final itemStatus = item['status']?.toString() ?? '';
      final number = item['order_number']?.toString() ?? '#$id';
      final customer = item['customer_name']?.toString() ?? 'Cliente';
      if (status.isNotEmpty && itemStatus != status) continue;
      if (query.isNotEmpty &&
          !number.toLowerCase().contains(query) &&
          !customer.toLowerCase().contains(query)) {
        continue;
      }
      items.add(
        OrderListItem(
          id: id,
          number: number,
          customerName: customer,
          address: item['address']?.toString() ?? '',
          city: item['city']?.toString() ?? '',
          state: item['state']?.toString() ?? '',
          status: itemStatus,
          units: _asInt(item['units']) ?? 0,
          weightGrams: _asInt(item['weight']) ?? 0,
          priority:
              _asInt(item['effective_priority']) ??
              _asInt(item['priority']) ??
              0,
          createdAt: _asDate(item['created_at']),
        ),
      );
    }

    items.sort((first, second) {
      final byDate = _compareNewest(first.createdAt, second.createdAt);
      return byDate != 0 ? byDate : second.id.compareTo(first.id);
    });
    return items;
  }

  void invalidateCache() {
    _cacheGeneration++;
    _cachedOrders = null;
    _cacheCreatedAt = null;
    _pageCache.clear();
  }

  /// Página e o instante em que a leitura começou (para sobrepor só o que
  /// o aparelho confirmou depois dela).
  Future<(PagedResult<OrderListItem>, DateTime?)> _getOrderPage(
    int page, {
    required bool refresh,
    String status = '',
  }) async {
    final key = '$status|$page';
    final cached = _pageCache[key];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.createdAt) < _cacheDuration) {
      return (cached.result, cached.createdAt);
    }

    final generation = _cacheGeneration;
    final ongoing = _pageOperations[key];
    final shared =
        ongoing != null && _pageOperationGenerations[key] == generation;
    // Leitura já em andamento (atualizar duas vezes seguidas): espera a
    // mesma, mas com o mesmo prazo e a mesma cópia do aparelho — antes a
    // segunda ficava presa na rede ruim e perdia a hora da leitura.
    final startedAt = shared
        ? _pageOperationStartedAt[key] ?? DateTime.now()
        : DateTime.now();
    final operation = shared ? ongoing : _loadOrderPage(page, status);
    if (!shared) {
      _pageOperations[key] = operation;
      _pageOperationGenerations[key] = generation;
      _pageOperationStartedAt[key] = startedAt;
    }
    try {
      final PagedResult<OrderListItem> result;
      try {
        result = await operation.timeout(OfflineDeadline.read);
      } catch (error) {
        // Sem sinal: a última cópia da lista principal salva no aparelho.
        final stored = status.isEmpty && isOfflineError(error)
            ? await _pageStore.read(page)
            : null;
        if (stored == null) rethrow;
        return (
          _pageFrom(stored['data'], page),
          DateTime.tryParse(stored['fetched_at']?.toString() ?? ''),
        );
      }
      if (generation == _cacheGeneration) {
        _pageCache[key] = _CachedOrderPage(startedAt, result);
      }
      return (result, startedAt);
    } finally {
      if (identical(_pageOperations[key], operation)) {
        _pageOperations.remove(key);
        _pageOperationGenerations.remove(key);
        _pageOperationStartedAt.remove(key);
      }
    }
  }

  Future<PagedResult<OrderListItem>> _loadOrderPage(
    int page,
    String status,
  ) async {
    final fetchedAt = DateTime.now().toUtc().toIso8601String();
    final response = await apiClient.dio.get<dynamic>(
      '/api/v1/delivery/pedidos/',
      // Mais novos primeiro: sem isso a página 1 trazia os pedidos mais
      // antigos da conta. Servidor antigo ignora o parâmetro.
      queryParameters: {
        'page': page,
        'ordering': '-id',
        'status': ?_nonEmpty(status),
      },
    );
    final data = response.data;
    if (status.isEmpty && data is Map) {
      unawaited(
        _pageStore.save(page, {
          'fetched_at': fetchedAt,
          'data': Map<String, dynamic>.from(data),
        }),
      );
    }
    return _pageFrom(data, page);
  }

  PagedResult<OrderListItem> _pageFrom(Object? data, int page) {
    final items = _parseItems(collectionItems(data));
    return PagedResult(
      items: items,
      count: data is Map ? _asInt(data['count']) ?? items.length : items.length,
      page: page,
      hasNext: data is Map && data['next'] != null,
      hasPrevious: data is Map ? data['previous'] != null : page > 1,
    );
  }

  static String? _nonEmpty(String value) => value.isEmpty ? null : value;

  /// Todos os pedidos (busca por texto) e o início da leitura.
  ///
  /// Sem sinal (ou rede "zumbi"), as páginas salvas no aparelho: antes a
  /// busca pelo número do pedido na rua esperava minutos e dava erro.
  Future<(List<Map<String, dynamic>>, DateTime?)> _getOrders({
    required bool refresh,
    String status = '',
  }) async {
    final cached = _cachedOrders;
    final createdAt = _cacheCreatedAt;
    final cacheIsFresh =
        cached != null &&
        _cachedOrdersStatus == status &&
        createdAt != null &&
        DateTime.now().difference(createdAt) < _cacheDuration;
    if (!refresh && cacheIsFresh) return (cached, _cacheReadAt);

    final ongoing = _loadOperation;
    final shared =
        ongoing != null &&
        _loadOperationGeneration == _cacheGeneration &&
        _loadOperationStatus == status;
    final generation = _cacheGeneration;
    final startedAt = shared
        ? _loadOperationStartedAt ?? DateTime.now()
        : DateTime.now();
    final operation = shared
        ? ongoing
        : apiClient.getAllPages(
            '/api/v1/delivery/pedidos/',
            queryParameters: {'status': ?_nonEmpty(status)},
          );
    if (!shared) {
      _loadOperationStatus = status;
      _loadOperation = operation;
      _loadOperationGeneration = generation;
      _loadOperationStartedAt = startedAt;
    }
    try {
      final orders = await operation.timeout(OfflineDeadline.read * 2);
      if (generation == _cacheGeneration) {
        _cachedOrders = orders;
        _cachedOrdersStatus = status;
        _cacheCreatedAt = DateTime.now();
        _cacheReadAt = startedAt;
      }
      return (orders, startedAt);
    } catch (error) {
      if (!isOfflineError(error)) rethrow;
      final stored = await _storedOrders();
      if (stored == null) rethrow;
      return stored;
    } finally {
      if (identical(_loadOperation, operation)) {
        _loadOperation = null;
        _loadOperationGeneration = null;
        _loadOperationStartedAt = null;
      }
    }
  }

  /// Páginas da lista salvas no aparelho, com a leitura mais antiga delas.
  Future<(List<Map<String, dynamic>>, DateTime?)?> _storedOrders() async {
    final orders = <Map<String, dynamic>>[];
    DateTime? oldest;
    // Página sem data: sobrepõe todas as ações confirmadas (nunca mais velho).
    var unknownDate = false;
    var found = false;
    for (var page = 1; page <= 50; page++) {
      final stored = await _pageStore.read(page);
      if (stored == null) break;
      found = true;
      orders.addAll(collectionItems(stored['data']));
      final readAt = DateTime.tryParse(stored['fetched_at']?.toString() ?? '');
      if (readAt == null) {
        unknownDate = true;
      } else if (oldest == null || readAt.isBefore(oldest)) {
        oldest = readAt;
      }
    }
    if (!found) return null;
    return (orders, unknownDate ? null : oldest);
  }

  int _compareNewest(DateTime? first, DateTime? second) {
    if (first == null && second == null) return 0;
    if (first == null) return 1;
    if (second == null) return -1;
    return second.compareTo(first);
  }

  /// Detalhe do pedido. Sem sinal, a última cópia salva no aparelho (o
  /// "Ver pedido" do mapa precisa funcionar na rua), com o status local.
  Future<OrderDetails> getOrderDetails(int orderId) async {
    final fetchedAt = DateTime.now();
    Map<String, dynamic> order;
    DateTime? readAt = fetchedAt;
    try {
      final response = await apiClient.dio
          .get<dynamic>('/api/v1/delivery/pedidos/$orderId/')
          .timeout(OfflineDeadline.read);
      order = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      if (order.isNotEmpty) {
        unawaited(
          _detailStore.save(orderId, {
            ...order,
            'fetched_at': fetchedAt.toUtc().toIso8601String(),
          }),
        );
      }
    } catch (error) {
      final stored = isOfflineError(error)
          ? await _storedOrderDetails(orderId)
          : null;
      if (stored == null) rethrow;
      (order, readAt) = stored;
    }
    final local = _localStatuses(readAt)[orderId];
    if (local != null) order['status'] = local;
    return OrderService.parseOrderDetails(order, orderId);
  }

  /// Cópia mais nova do pedido no aparelho: a do detalhe, a da lista ou a
  /// da rota do mapa (a API usa o mesmo formato). Sem isso, o "Ver pedido"
  /// sem sinal só abria pedidos já abertos antes com rede.
  Future<(Map<String, dynamic>, DateTime?)?> _storedOrderDetails(
    int orderId,
  ) async {
    Map<String, dynamic>? best;
    DateTime? bestAt;
    void consider(Map<String, dynamic> candidate, Object? fetchedAt) {
      final at = DateTime.tryParse(fetchedAt?.toString() ?? '');
      final newer =
          best == null ||
          (at != null && (bestAt == null || at.isAfter(bestAt!)));
      if (!newer) return;
      best = candidate;
      bestAt = at;
    }

    final detail = await _detailStore.read(orderId);
    if (detail != null) consider(detail, detail['fetched_at']);
    for (var page = 1; page <= 50; page++) {
      final stored = await _pageStore.read(page);
      if (stored == null) break;
      for (final item in collectionItems(stored['data'])) {
        if (_asInt(item['id']) == orderId) {
          consider(Map<String, dynamic>.from(item), stored['fetched_at']);
        }
      }
    }
    // Só as rotas mais recentes: o pedido aberto na rua é da rota de hoje.
    for (final routeId in (await _routeStore.savedIds()).take(5)) {
      final stored = await _routeStore.read(routeId);
      final orders = stored?['orders'];
      if (orders is! List) continue;
      for (final item in orders.whereType<Map>()) {
        if (_asInt(item['id']) == orderId) {
          consider(Map<String, dynamic>.from(item), stored?['fetched_at']);
        }
      }
    }
    final found = best;
    return found == null ? null : (found, bestAt);
  }

  /// Conteúdo da última cópia gravada por pedido (sem regravar o que não
  /// mudou: o detalhe da carga é relido a cada evento em tempo real).
  final Map<int, int> _rememberedHash = {};

  /// Guarda no aparelho os pedidos lidos com a carga (antes de existir rota
  /// eles não estão em nenhuma cópia), para o "Ver pedido" abrir sem sinal.
  void rememberOrders(List<Map<String, dynamic>> orders) {
    final fetchedAt = DateTime.now().toUtc().toIso8601String();
    for (final order in orders) {
      final orderId = _asInt(order['id']);
      if (orderId == null) continue;
      final hash = jsonEncode(order).hashCode;
      if (_rememberedHash[orderId] == hash) continue;
      _rememberedHash[orderId] = hash;
      unawaited(
        _detailStore.save(orderId, {...order, 'fetched_at': fetchedAt}),
      );
    }
  }

  /// Logout/troca de conta sem nada pendente: não deixa cópias para trás.
  Future<void> clearStoredCopies() async {
    _rememberedHash.clear();
    await _detailStore.clear();
    await _pageStore.clear();
  }

  static OrderDetails parseOrderDetails(dynamic data, int orderId) {
    final order = data is Map
        ? Map<String, dynamic>.from(data)
        : <String, dynamic>{};
    final rawItems = order['items'];
    final items = <OrderItemDetails>[];

    if (rawItems is List) {
      for (final rawItem in rawItems.whereType<Map>()) {
        final item = Map<String, dynamic>.from(rawItem);
        final rawVolumes = item['volumes'];
        final volumes = <OrderVolumeDetails>[];
        if (rawVolumes is List) {
          for (final rawVolume in rawVolumes.whereType<Map>()) {
            final volume = Map<String, dynamic>.from(rawVolume);
            volumes.add(
              OrderVolumeDetails(
                id: _asInt(volume['id']) ?? 0,
                lengthCentimeters: _asDouble(volume['length_cm']) ?? 0,
                widthCentimeters: _asDouble(volume['width_cm']) ?? 0,
                heightCentimeters: _asDouble(volume['height_cm']) ?? 0,
                weightGrams: _asInt(volume['weight_g']) ?? 0,
              ),
            );
          }
        }
        items.add(
          OrderItemDetails(
            id: _asInt(item['id']) ?? 0,
            name: item['name']?.toString() ?? 'Item',
            volumes: volumes,
            status: item['status']?.toString() ?? 'pending',
            failureReason: item['failure_reason']?.toString() ?? '',
            failureNotes: item['failure_notes']?.toString() ?? '',
          ),
        );
      }
    }

    final rawSkills = order['skills'];
    final rawProofOverrides = order['proof_overrides'];
    return OrderDetails(
      id: _asInt(order['id']) ?? orderId,
      number: order['order_number']?.toString() ?? '#$orderId',
      externalSource: order['external_source']?.toString() ?? '',
      externalId: order['external_id']?.toString() ?? '',
      customerName: order['customer_name']?.toString() ?? 'Cliente',
      customerPhone: order['customer_phone']?.toString() ?? '',
      warehouseId: _asInt(order['warehouse']),
      address: order['address']?.toString() ?? '',
      addressNumber: order['address_number']?.toString() ?? '',
      addressComplement: order['address_complement']?.toString() ?? '',
      neighborhood: order['neighborhood']?.toString() ?? '',
      city: order['city']?.toString() ?? '',
      state: order['state']?.toString() ?? '',
      postalCode: order['postal_code']?.toString() ?? '',
      latitude: _asDouble(order['lat']),
      longitude: _asDouble(order['lon']),
      volumeCubicCentimeters: _asInt(order['volume']) ?? 0,
      weightGrams: _asInt(order['weight']) ?? 0,
      units: _asInt(order['units']) ?? 0,
      priority: _asInt(order['priority']) ?? 0,
      effectivePriority: _asInt(order['effective_priority']) ?? 0,
      skills: rawSkills is List
          ? rawSkills.map((item) => item.toString()).toList()
          : const [],
      serviceDurationSeconds: _asInt(order['service_duration_seconds']) ?? 0,
      deliveryWindowStart: _asDate(order['delivery_window_start']),
      deliveryWindowEnd: _asDate(order['delivery_window_end']),
      readyAt: _asDate(order['ready_at']),
      promisedAt: _asDate(order['promised_at']),
      status: order['status']?.toString() ?? '',
      unassignedReason: order['unassigned_reason']?.toString() ?? '',
      proofOverrides: rawProofOverrides is Map
          ? Map<String, dynamic>.from(rawProofOverrides)
          : const {},
      notes: _orderNotes(order),
      paymentMethod: order['payment_method']?.toString().trim() ?? '',
      paymentValue: _asDouble(order['payment_value']),
      splitFromId: _relationId(order['split_from']),
      createdAt: _asDate(order['created_at']),
      updatedAt: _asDate(order['updated_at']),
      items: items,
    );
  }

  /// A observacao do pedido nao tem nome unico nas integracoes que alimentam a
  /// API; a primeira chave preenchida vence.
  static String _orderNotes(Map<String, dynamic> order) {
    const keys = ['notes', 'note', 'observation', 'observacao', 'observations'];
    for (final key in keys) {
      final value = order[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static int? _relationId(dynamic value) {
    if (value is Map) return _asInt(value['id']);
    return _asInt(value);
  }

  static DateTime? _asDate(dynamic value) =>
      DateTime.tryParse(value?.toString() ?? '');

  static double? _asDouble(dynamic value) => switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text),
    _ => null,
  };

  static int? _asInt(dynamic value) => switch (value) {
    int number => number,
    String text => int.tryParse(text),
    _ => null,
  };
}
