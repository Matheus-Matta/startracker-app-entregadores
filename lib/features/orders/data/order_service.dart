import '../../../core/network/api_client.dart';
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
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<OrderItemDetails> items;

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

class OrderService {
  const OrderService(this.apiClient);
  final ApiClient apiClient;

  Future<PagedResult<OrderListItem>> getOrders({
    required int page,
    String search = '',
    String status = '',
  }) async {
    const pageSize = 20;
    final rawItems = await _getAll('/api/v1/delivery/pedidos/');
    final query = search.trim().toLowerCase();
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

  Future<List<Map<String, dynamic>>> _getAll(String path) async {
    final items = <Map<String, dynamic>>[];
    var page = 1;
    while (page <= 100) {
      final response = await apiClient.dio.get<dynamic>(
        path,
        queryParameters: {'page': page},
      );
      final data = response.data;
      final raw = data is Map ? data['results'] : data;
      if (raw is List) {
        items.addAll(
          raw.whereType<Map>().map((item) => Map<String, dynamic>.from(item)),
        );
      }
      if (data is! Map || data['next'] == null) break;
      page++;
    }
    return items;
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
    final data = response.data;
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
      createdAt: _asDate(order['created_at']),
      updatedAt: _asDate(order['updated_at']),
      items: items,
    );
  }

  DateTime? _asDate(dynamic value) =>
      DateTime.tryParse(value?.toString() ?? '');

  double? _asDouble(dynamic value) => switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text),
    _ => null,
  };

  int? _asInt(dynamic value) => switch (value) {
    int number => number,
    String text => int.tryParse(text),
    _ => null,
  };
}
