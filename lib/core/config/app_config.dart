import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  static String get backendUrl {
    const configuredUrl = String.fromEnvironment('BACKEND_URL');
    if (configuredUrl.isNotEmpty) return configuredUrl;

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8000';
    }
    return 'http://localhost:8000';
  }
}
