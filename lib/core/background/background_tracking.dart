import 'package:workmanager/workmanager.dart';

const trackingTask = 'delivery-location-sync';

@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // Integre aqui o envio da localização ao endpoint do backend.
    return true;
  });
}

class BackgroundTracking {
  Future<void> initialize() =>
      Workmanager().initialize(backgroundCallbackDispatcher);

  Future<void> start() => Workmanager().registerPeriodicTask(
    trackingTask,
    trackingTask,
    frequency: const Duration(minutes: 15),
  );

  Future<void> stop() => Workmanager().cancelByUniqueName(trackingTask);
}
