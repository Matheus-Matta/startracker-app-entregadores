import 'package:geolocator/geolocator.dart';

class LocationService {
  Future<Position> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationServiceDisabledException();
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const PermissionDeniedException('Permissão de localização negada.');
    }

    // getCurrentPosition solicita uma leitura nova; getLastKnownPosition nao e
    // usado aqui para que uma confirmacao nunca reaproveite cache antigo.
    return Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.best,
        timeLimit: timeout,
      ),
    );
  }

  Stream<Position> watchPosition() => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    ),
  );
}
