import '../../../core/network/api_client.dart';
import '../../../core/network/api_collection.dart';
import '../../../core/network/paged_result.dart';

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
  OrderService(this.apiClient);
  final ApiClient apiClient;
  static const _cacheDuration = Duration(seconds: 30);
  List<Map<String, dynamic>>? _cachedOrders;
  DateTime? _cacheCreatedAt;
  Future<List<Map<String, dynamic>>>? _loadOperation;
  final Map<int, _CachedOrderPage> _pageCache = {};
  final Map<int, Future<PagedResult<OrderListItem>>> _pageOperations = {};
  final Map<int, int> _pageOperationGenerations = {};
  int? _loadOperationGeneration;
  int _cacheGeneration = 0;

  Future<PagedResult<OrderListItem>> getOrders({
    required int page,
    String search = '',
    String status = '',
    bool refresh = false,
  }) async {
    final query = search.trim().toLowerCase();
    if (query.isEmpty && status.isEmpty) {
      return _getOrderPage(page, refresh: refresh);
    }

    const pageSize = 20;
    final rawItems = await _getOrders(refresh: refresh);
    final items = _parseItems(rawItems, query: query, status: status);

    final start = (page - 1) * pageSize;
    final pageItems = start >= items.length
        ? const <OrderListItem>[]
        : items.sublist(
            start,
            start + pageSize < items.length ? start + pageSize : items.length,
          );

    return PagedResult(
      items: pageItems,
      count: items.length,
      page: page,
      hasNext: start + pageSize < items.length,
      hasPrevious: page > 1,
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

  Future<PagedResult<OrderListItem>> _getOrderPage(
    int page, {
    required bool refresh,
  }) async {
    final cached = _pageCache[page];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.createdAt) < _cacheDuration) {
      return cached.result;
    }

    final ongoing = _pageOperations[page];
    if (ongoing != null &&
        _pageOperationGenerations[page] == _cacheGeneration) {
      return ongoing;
    }
    final generation = _cacheGeneration;
    final operation = _loadOrderPage(page);
    _pageOperations[page] = operation;
    _pageOperationGenerations[page] = generation;
    try {
      final result = await operation;
      if (generation == _cacheGeneration) {
        _pageCache[page] = _CachedOrderPage(DateTime.now(), result);
      }
      return result;
    } finally {
      if (identical(_pageOperations[page], operation)) {
        _pageOperations.remove(page);
        _pageOperationGenerations.remove(page);
      }
    }
  }

  Future<PagedResult<OrderListItem>> _loadOrderPage(int page) async {
    final response = await apiClient.dio.get<dynamic>(
      '/api/v1/delivery/pedidos/',
      queryParameters: {'page': page},
    );
    final data = response.data;
    final items = _parseItems(collectionItems(data));
    return PagedResult(
      items: items,
      count: data is Map ? _asInt(data['count']) ?? items.length : items.length,
      page: page,
      hasNext: data is Map && data['next'] != null,
      hasPrevious: data is Map ? data['previous'] != null : page > 1,
    );
  }

  Future<List<Map<String, dynamic>>> _getOrders({required bool refresh}) async {
    final cached = _cachedOrders;
    final createdAt = _cacheCreatedAt;
    final cacheIsFresh =
        cached != null &&
        createdAt != null &&
        DateTime.now().difference(createdAt) < _cacheDuration;
    if (!refresh && cacheIsFresh) return cached;

    final ongoing = _loadOperation;
    if (ongoing != null && _loadOperationGeneration == _cacheGeneration) {
      return ongoing;
    }

    final generation = _cacheGeneration;
    final operation = apiClient.getAllPages('/api/v1/delivery/pedidos/');
    _loadOperation = operation;
    _loadOperationGeneration = generation;
    try {
      final orders = await operation;
      if (generation == _cacheGeneration) {
        _cachedOrders = orders;
        _cacheCreatedAt = DateTime.now();
      }
      return orders;
    } finally {
      if (identical(_loadOperation, operation)) {
        _loadOperation = null;
        _loadOperationGeneration = null;
      }
    }
  }

  int _compareNewest(DateTime? first, DateTime? second) {
    if (first == null && second == null) return 0;
    if (first == null) return 1;
    if (second == null) return -1;
    return second.compareTo(first);
  }

  Future<OrderDetails> getOrderDetails(int orderId) async {
    final response = await apiClient.dio.get<dynamic>(
      '/api/v1/delivery/pedidos/$orderId/',
    );
    return OrderService.parseOrderDetails(response.data, orderId);
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
