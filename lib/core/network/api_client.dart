import 'package:dio/dio.dart';

import '../storage/session_storage.dart';

class ApiClient {
  ApiClient({required String baseUrl, required SessionStorage storage})
    : _baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
      _storage = storage,
      dio = Dio(
        BaseOptions(
          baseUrl: baseUrl.replaceFirst(RegExp(r'/$'), ''),
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: const {'Accept': 'application/json'},
        ),
      ) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await storage.readToken();
          if (token != null) options.headers['Authorization'] = 'Bearer $token';
          handler.next(options);
        },
        onError: (error, handler) async {
          final request = error.requestOptions;
          if (error.response?.statusCode != 401 ||
              request.extra['tokenRefreshAttempted'] == true ||
              _isLoginOrTokenRequest(request.path)) {
            handler.next(error);
            return;
          }

          final access = await _refreshAccessToken();
          if (access == null) {
            handler.next(error);
            return;
          }

          request.extra['tokenRefreshAttempted'] = true;
          request.headers['Authorization'] = 'Bearer $access';
          try {
            handler.resolve(await dio.fetch<dynamic>(request));
          } on DioException catch (retryError) {
            handler.next(retryError);
          }
        },
      ),
    );
  }

  static Future<String?>? _refreshOperation;

  final String _baseUrl;
  final SessionStorage _storage;
  final Dio dio;

  bool _isLoginOrTokenRequest(String path) {
    return path.endsWith('/api/v1/auth/entregadores/token/') ||
        path.endsWith('/api/v1/auth/token/') ||
        path.endsWith('/api/v1/auth/token/verify/') ||
        path.endsWith('/api/v1/auth/token/refresh/');
  }

  Future<String?> _refreshAccessToken() async {
    final ongoing = _refreshOperation;
    if (ongoing != null) return ongoing;

    final operation = _requestNewAccessToken();
    _refreshOperation = operation;
    try {
      return await operation;
    } finally {
      if (identical(_refreshOperation, operation)) {
        _refreshOperation = null;
      }
    }
  }

  Future<String?> _requestNewAccessToken() async {
    final refresh = await _storage.readRefreshToken();
    if (refresh == null || refresh.isEmpty) return null;

    final refreshClient = Dio(
      BaseOptions(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: const {'Accept': 'application/json'},
      ),
    );

    try {
      final response = await refreshClient.post<dynamic>(
        '/api/v1/auth/token/refresh/',
        data: {'refresh': refresh},
      );
      final data = response.data;
      if (data is! Map) return null;

      final access = data['access']?.toString();
      if (access == null || access.isEmpty) return null;

      final rotatedRefresh = data['refresh']?.toString();
      if (rotatedRefresh != null && rotatedRefresh.isNotEmpty) {
        await _storage.saveTokens(access: access, refresh: rotatedRefresh);
      } else {
        await _storage.saveToken(access);
      }
      return access;
    } on DioException catch (error) {
      if (error.response?.statusCode == 400 ||
          error.response?.statusCode == 401) {
        await _storage.clear();
      }
      return null;
    }
  }
}
