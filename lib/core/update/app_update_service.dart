import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Versão nova disponível para instalar.
@immutable
class AppUpdate {
  const AppUpdate({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
  });

  final String currentVersion;
  final String latestVersion;

  /// Android: link direto do APK no GitHub. iOS: página do app na App Store.
  final Uri downloadUrl;
}

/// Verifica se existe versão mais nova do app.
///
/// * Android: última release do GitHub. Usa o redirecionamento de
///   `releases/latest` em vez da API REST, que limita 60 consultas por hora
///   por IP — e no 4G milhares de aparelhos dividem o mesmo IP da operadora.
///   Antes de avisar, confirma que o APK foi anexado à release (a release é
///   criada mesmo quando o build Android falha).
/// * iOS: consulta pública da App Store pelo bundle id.
///
/// Qualquer falha de rede é silenciosa: o aviso é um extra e nunca pode
/// atrapalhar o trabalho do entregador.
class AppUpdateService {
  AppUpdateService({
    Dio? http,
    Future<PackageInfo> Function()? packageInfo,
    this.platform,
    this.githubRepository = const String.fromEnvironment(
      'UPDATE_GITHUB_REPOSITORY',
      defaultValue: 'Matheus-Matta/startracker-app-entregadores',
    ),
    this.androidApkName = const String.fromEnvironment(
      'UPDATE_ANDROID_APK_NAME',
      defaultValue: 'StarTracker-Entregas.apk',
    ),
    this.appStoreCountry = 'br',
  }) : _http =
           http ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 10),
               followRedirects: false,
               validateStatus: (status) => status != null && status < 500,
             ),
           ),
       _packageInfo = packageInfo ?? PackageInfo.fromPlatform;

  final Dio _http;
  final Future<PackageInfo> Function() _packageInfo;
  /// Só para testes; no app vale a plataforma atual.
  final TargetPlatform? platform;
  final String githubRepository;
  final String androidApkName;
  final String appStoreCountry;

  TargetPlatform get _currentPlatform => platform ?? defaultTargetPlatform;

  Future<AppUpdate?> check() async {
    if (kIsWeb) return null;
    try {
      final info = await _packageInfo();
      return switch (_currentPlatform) {
        TargetPlatform.android => await _checkGithub(info.version),
        TargetPlatform.iOS => await _checkAppStore(
          info.version,
          info.packageName,
        ),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<AppUpdate?> _checkGithub(String current) async {
    final latest = await _http.get<dynamic>(
      'https://github.com/$githubRepository/releases/latest',
      options: Options(responseType: ResponseType.plain),
    );
    final location = latest.headers.value('location') ?? '';
    final tag = Uri.tryParse(location)?.pathSegments.lastOrNull ?? '';
    if (!location.contains('/releases/tag/') || tag.isEmpty) return null;
    final latestVersion = normalizeVersion(tag);
    if (!isNewer(latestVersion, current)) return null;

    final apk = Uri.parse(
      'https://github.com/$githubRepository/releases/download/'
      '${Uri.encodeComponent(tag)}/$androidApkName',
    );
    // 302 para o armazenamento do GitHub = o arquivo existe.
    final asset = await _http.head<dynamic>(apk.toString());
    final status = asset.statusCode ?? 0;
    if (status < 200 || status >= 400) return null;
    return AppUpdate(
      currentVersion: current,
      latestVersion: latestVersion,
      downloadUrl: apk,
    );
  }

  Future<AppUpdate?> _checkAppStore(String current, String bundleId) async {
    final response = await _http.get<dynamic>(
      'https://itunes.apple.com/lookup',
      queryParameters: {
        'bundleId': bundleId,
        'country': appStoreCountry,
        // A consulta da Apple usa CDN; isso evita uma resposta antiga.
        '_': DateTime.now().millisecondsSinceEpoch ~/ 3600000,
      },
      options: Options(responseType: ResponseType.json),
    );
    final data = response.data;
    if (data is! Map || data['results'] is! List) return null;
    final results = data['results'] as List;
    if (results.isEmpty || results.first is! Map) return null;
    final app = results.first as Map;
    final latestVersion = normalizeVersion(app['version']?.toString() ?? '');
    final trackId = app['trackId']?.toString() ?? '';
    if (latestVersion.isEmpty || trackId.isEmpty) return null;
    if (!isNewer(latestVersion, current)) return null;
    return AppUpdate(
      currentVersion: current,
      latestVersion: latestVersion,
      downloadUrl: Uri.parse('https://apps.apple.com/app/id$trackId'),
    );
  }

  /// `v1.0.55+9` → `1.0.55`.
  static String normalizeVersion(String value) {
    var version = value.trim();
    if (version.startsWith('v') || version.startsWith('V')) {
      version = version.substring(1);
    }
    return version.split(RegExp(r'[+\-]')).first;
  }

  /// Compara versões numéricas (`1.1` > `1.0.54`).
  static bool isNewer(String candidate, String current) {
    List<int> parts(String value) => normalizeVersion(
      value,
    ).split('.').map((part) => int.tryParse(part) ?? 0).toList();
    final left = parts(candidate);
    final right = parts(current);
    final length = left.length > right.length ? left.length : right.length;
    for (var index = 0; index < length; index++) {
      final a = index < left.length ? left[index] : 0;
      final b = index < right.length ? right[index] : 0;
      if (a != b) return a > b;
    }
    return false;
  }
}
