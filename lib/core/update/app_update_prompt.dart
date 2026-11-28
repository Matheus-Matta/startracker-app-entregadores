import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../presentation/app_messages.dart';
import 'app_update_installer.dart';
import 'app_update_service.dart';

const _ink = Color(0xFF171713);
const _yellow = Color(0xFFF8E94E);

/// Controla quando o aviso de versão nova aparece.
///
/// * consulta no máximo a cada [_checkInterval] (uma requisição pequena);
/// * cada versão é anunciada uma vez por sessão do app — "Depois" não
///   insiste até o app ser aberto de novo;
/// * só abre se a tela que pediu estiver visível, para nunca interromper
///   uma entrega, a câmera ou a conferência.
class AppUpdatePrompt {
  AppUpdatePrompt._();

  static final AppUpdatePrompt instance = AppUpdatePrompt._();

  static const _checkInterval = Duration(hours: 6);

  AppUpdateService service = AppUpdateService();
  AppUpdateInstaller installer = AppUpdateInstaller();
  DateTime? _lastCheckAt;
  bool _checking = false;
  final Set<String> _announced = {};

  Future<void> maybeShow(BuildContext context) async {
    if (_checking) return;
    final last = _lastCheckAt;
    if (last != null && DateTime.now().difference(last) < _checkInterval) {
      return;
    }
    _checking = true;
    try {
      final update = await service.check();
      _lastCheckAt = DateTime.now();
      if (update == null || _announced.contains(update.latestVersion)) return;
      if (!context.mounted) return;
      final route = ModalRoute.of(context);
      // Outra tela por cima: tenta de novo na próxima volta ao app.
      if (route != null && !route.isCurrent) {
        _lastCheckAt = null;
        return;
      }
      _announced.add(update.latestVersion);
      final selfUpdate = await installer.canSelfUpdate();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        // Baixando: tocar fora não pode sumir com o download.
        barrierDismissible: false,
        builder: (_) => _AppUpdateDialog(
          update: update,
          installer: installer,
          selfUpdate: selfUpdate,
        ),
      );
    } finally {
      _checking = false;
    }
  }
}

enum _Stage { offer, downloading, ready, needsPermission }

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({
    required this.update,
    required this.installer,
    required this.selfUpdate,
  });

  final AppUpdate update;
  final AppUpdateInstaller installer;

  /// APK direto no Android: baixa e instala aqui dentro.
  final bool selfUpdate;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog>
    with WidgetsBindingObserver {
  _Stage _stage = _Stage.offer;
  double? _progress;
  CancelToken? _cancel;
  File? _apk;
  String? _error;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Voltou das configurações depois de liberar a instalação: segue já.
    if (state == AppLifecycleState.resumed &&
        _stage == _Stage.needsPermission) {
      unawaited(_install());
    }
  }

  Future<void> _download() async {
    final cancel = CancelToken();
    setState(() {
      _stage = _Stage.downloading;
      _progress = null;
      _error = null;
      _cancel = cancel;
    });
    try {
      final apk = await widget.installer.download(
        widget.update.downloadUrl,
        version: widget.update.latestVersion,
        cancelToken: cancel,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _apk = apk;
        _stage = _Stage.ready;
      });
      await _install();
    } on DioException catch (error) {
      if (!mounted || CancelToken.isCancel(error)) return;
      setState(() {
        _stage = _Stage.offer;
        _error = 'Não foi possível baixar a versão nova. Tente de novo.';
      });
    } on AppUpdateInstallException catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.offer;
        _error = error.message;
      });
    }
  }

  void _cancelDownload() {
    _cancel?.cancel();
    setState(() {
      _stage = _Stage.offer;
      _progress = null;
    });
  }

  Future<void> _install() async {
    final apk = _apk;
    if (apk == null) return;
    try {
      final result = await widget.installer.install(apk);
      if (!mounted) return;
      setState(() {
        _error = null;
        _stage = result == AppUpdateInstallResult.needsPermission
            ? _Stage.needsPermission
            : _Stage.ready;
      });
    } on AppUpdateInstallException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  /// iOS (App Store) ou Android instalado pela Play: a loja é quem atualiza.
  Future<void> _openStore() async {
    final navigator = Navigator.of(context);
    var url = widget.update.downloadUrl;
    if (_isAndroid) {
      final info = await PackageInfo.fromPlatform();
      url = Uri.parse(
        'https://play.google.com/store/apps/details?id=${info.packageName}',
      );
    }
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    if (!opened) {
      showAppMessage(
        context,
        'Não foi possível abrir a loja. Tente novamente mais tarde.',
      );
      return;
    }
    navigator.pop();
  }

  String get _message {
    final versions =
        'A versão ${widget.update.latestVersion} está pronta (você usa a '
        '${widget.update.currentVersion}).';
    if (!widget.selfUpdate) {
      return _isAndroid
          ? '$versions\n\nToque em "Atualizar" para abrir a Play Store.'
          : '$versions\n\nToque em "Atualizar" para abrir a App Store.';
    }
    return switch (_stage) {
      _Stage.offer =>
        '$versions\n\nO download e a instalação acontecem aqui mesmo, sem '
            'sair do app. O que estiver para enviar fica salvo e continua '
            'depois da atualização.',
      _Stage.downloading => 'Baixando a versão ${widget.update.latestVersion}…',
      _Stage.ready =>
        'Download concluído. Confirme a instalação na janela do Android. '
            'Se ela não abriu, toque em "Instalar".',
      _Stage.needsPermission =>
        'O Android precisa da sua permissão para instalar a atualização. '
            'Ative "Permitir desta fonte" e volte para o app: a instalação '
            'segue sozinha.',
    };
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _stage != _Stage.downloading,
    child: AlertDialog(
      icon: const Icon(Icons.system_update_rounded, color: _ink, size: 34),
      title: const Text(
        'Nova versão disponível',
        textAlign: TextAlign.center,
        style: TextStyle(fontWeight: FontWeight.w900),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_message, style: const TextStyle(height: 1.35)),
          if (_stage == _Stage.downloading) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 10,
                color: _ink,
                backgroundColor: _yellow,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _progress == null
                  ? 'Calculando o tamanho…'
                  : '${(_progress! * 100).clamp(0, 100).toStringAsFixed(0)}%',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(
                color: Color(0xFFB42318),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: _actions(context),
    ),
  );

  List<Widget> _actions(BuildContext context) {
    final later = TextButton(
      onPressed: () => Navigator.of(context).pop(),
      style: TextButton.styleFrom(foregroundColor: _ink),
      child: const Text('Depois'),
    );
    Widget primary(String label, IconData icon, VoidCallback onPressed) =>
        FilledButton.icon(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: _yellow,
            foregroundColor: _ink,
          ),
          icon: Icon(icon),
          label: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        );
    if (!widget.selfUpdate) {
      return [
        later,
        primary(
          'Atualizar',
          Icons.open_in_new_rounded,
          () => unawaited(_openStore()),
        ),
      ];
    }
    return switch (_stage) {
      _Stage.offer => [
        later,
        primary(
          _error == null ? 'Baixar' : 'Tentar de novo',
          Icons.download_rounded,
          () => unawaited(_download()),
        ),
      ],
      _Stage.downloading => [
        TextButton(
          onPressed: _cancelDownload,
          style: TextButton.styleFrom(foregroundColor: _ink),
          child: const Text('Cancelar'),
        ),
      ],
      _Stage.ready || _Stage.needsPermission => [
        later,
        primary(
          _stage == _Stage.needsPermission ? 'Permitir' : 'Instalar',
          Icons.install_mobile_rounded,
          () => unawaited(_install()),
        ),
      ],
    };
  }
}
