enum DeliveryStatus { awaitingPickup, onTheWay, delivered }

class Delivery {
  const Delivery({
    required this.id,
    required this.customerName,
    required this.address,
    required this.status,
  });

  final String id;
  final String customerName;
  final String address;
  final DeliveryStatus status;

  Delivery copyWith({DeliveryStatus? status}) => Delivery(
    id: id,
    customerName: customerName,
    address: address,
    status: status ?? this.status,
  );
}
