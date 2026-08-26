class NotificationPreferences {
  const NotificationPreferences({
    required this.newWaves,
    required this.routeChanges,
    required this.orderUpdates,
  });

  static const defaults = NotificationPreferences(
    newWaves: true,
    routeChanges: true,
    orderUpdates: false,
  );

  final bool newWaves;
  final bool routeChanges;
  final bool orderUpdates;

  bool get anyEnabled => newWaves || routeChanges || orderUpdates;

  NotificationPreferences copyWith({
    bool? newWaves,
    bool? routeChanges,
    bool? orderUpdates,
  }) => NotificationPreferences(
    newWaves: newWaves ?? this.newWaves,
    routeChanges: routeChanges ?? this.routeChanges,
    orderUpdates: orderUpdates ?? this.orderUpdates,
  );
}
