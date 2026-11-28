import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Resultado de pedir a instalação ao Android.
enum AppUpdateInstallResult {
  /// O instalador do Android abriu (o entregador confirma ali).
  started,

  /// Falta liberar "instalar apps desta fonte"; as configurações abriram.
  needsPermission,
}

class AppUpdateInstallException implements Exception {
  const AppUpdateInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Baixa e instala a versão nova sem sair do app (Android, APK direto).
///
/// Antes o aviso abria o navegador: o entregador saía do app, procurava o
/// arquivo nos downloads e muitas vezes não voltava. Agora o download corre
/// aqui, com progresso, e o instalador do Android abre por cima do app.
///
/// Instalado pela Play Store não se atualiza sozinho: a Play proíbe, e o
/// AAB nem tem a permissão (ver `android/app/build.gradle.kts`).
class AppUpdateInstaller {
  AppUpdateInstaller({
    Dio? http,
    MethodChannel? channel,
    Future<Directory> Function()? cacheDirectory,
    this.platform,
  }) : _http =
           http ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               // Entre pedaços do arquivo; o download inteiro pode levar
               // minutos no 4G.
               receiveTimeout: const Duration(seconds: 60),
             ),
           ),
       _channel =
           channel ??
           const MethodChannel('br.dev.star.tracker.entregas/app_update'),
       _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  final Dio _http;
  final MethodChannel _channel;
  final Future<Directory> Function() _cacheDirectory;

  /// Só para testes; no app vale a plataforma atual.
  final TargetPlatform? platform;

  bool get _isAndroid =>
      !kIsWeb && (platform ?? defaultTargetPlatform) == TargetPlatform.android;

  /// O app pode baixar e instalar a versão nova por conta própria.
  Future<bool> canSelfUpdate() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canSelfUpdate') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Baixa o APK para o cache do app. [onProgress] recebe de 0 a 1 (ou
  /// `null` quando o servidor não informa o tamanho).
  Future<File> download(
    Uri url, {
    required String version,
    void Function(double? progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final folder = Directory(
      '${(await _cacheDirectory()).path}${Platform.pathSeparator}updates',
    );
    // Instaladores de versões anteriores só ocupam espaço.
    if (await folder.exists()) {
      try {
        await folder.delete(recursive: true);
      } catch (_) {}
    }
    await folder.create(recursive: true);
    final safeVersion = version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final target = File(
      '${folder.path}${Platform.pathSeparator}StarTracker-Entregas-$safeVersion.apk',
    );
    // Gravado à parte e renomeado no fim: um download interrompido nunca é
    // entregue ao instalador como se estivesse completo.
    final partial = File('${target.path}.part');
    try {
      await _http.downloadUri(
        url,
        partial.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          onProgress?.call(total > 0 ? received / total : null);
        },
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw const AppUpdateInstallException(
        'Não foi possível baixar a versão nova. Verifique a conexão e tente '
        'de novo.',
      );
    }
    if (!await _looksLikeApk(partial)) {
      try {
        await partial.delete();
      } catch (_) {}
      throw const AppUpdateInstallException(
        'O arquivo baixado não é um instalador válido. Tente de novo mais '
        'tarde.',
      );
    }
    return partial.rename(target.path);
  }

  /// APK é um ZIP: começa com "PK". Uma página de erro (HTML) do servidor
  /// ou um arquivo vazio não pode ir para o instalador.
  static Future<bool> _looksLikeApk(File file) async {
    try {
      if (await file.length() < 1024) return false;
      final head = await file.openRead(0, 2).first;
      return head.length == 2 && head[0] == 0x50 && head[1] == 0x4B;
    } catch (_) {
      return false;
    }
  }

  /// Abre o instalador do Android para o APK baixado. Sem a liberação de
  /// "instalar apps desta fonte", abre essa configuração primeiro.
  Future<AppUpdateInstallResult> install(File apk) async {
    try {
      final allowed = await _channel.invokeMethod<bool>('canInstall') ?? false;
      if (!allowed) {
        await _channel.invokeMethod<void>('openInstallSettings');
        return AppUpdateInstallResult.needsPermission;
      }
      await _channel.invokeMethod<bool>('install', {'path': apk.path});
      return AppUpdateInstallResult.started;
    } on PlatformException {
      throw const AppUpdateInstallException(
        'Não foi possível abrir o instalador do Android. Tente de novo.',
      );
    }
  }
}
