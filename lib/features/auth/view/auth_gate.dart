import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/session_storage.dart';
import '../../delivery/view/delivery_page.dart';
import '../data/auth_service.dart';
import 'login_page.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Future<bool> _session;

  @override
  void initState() {
    super.initState();
    const storage = SessionStorage();
    final authService = AuthService(
      apiClient: ApiClient(baseUrl: AppConfig.backendUrl, storage: storage),
      storage: storage,
    );
    _session = _restoreSafely(authService);
  }

  Future<bool> _restoreSafely(AuthService authService) async {
    try {
      return await authService.restoreSession();
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _session,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: CircularProgressIndicator(color: Color(0xFF020617)),
            ),
          );
        }
        return snapshot.data == true ? const DeliveryPage() : const LoginPage();
      },
    );
  }
}
