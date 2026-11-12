import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../presentation/app_messages.dart';
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
      await showDialog<void>(
        context: context,
        builder: (_) => _AppUpdateDialog(update: update),
      );
    } finally {
      _checking = false;
    }
  }
}

class _AppUpdateDialog extends StatelessWidget {
  const _AppUpdateDialog({required this.update});

  final AppUpdate update;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  Future<void> _open(BuildContext context) async {
    final navigator = Navigator.of(context);
    var opened = false;
    try {
      opened = await launchUrl(
        update.downloadUrl,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (!context.mounted) return;
    if (!opened) {
      showAppMessage(
        context,
        'Não foi possível abrir o link. Tente novamente mais tarde.',
      );
      return;
    }
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.system_update_rounded, color: _ink, size: 34),
    title: const Text(
      'Nova versão disponível',
      textAlign: TextAlign.center,
      style: TextStyle(fontWeight: FontWeight.w900),
    ),
    content: Text(
      _isAndroid
          ? 'A versão ${update.latestVersion} está pronta (você usa a '
                '${update.currentVersion}).\n\nToque em "Baixar" para '
                'baixar o instalador. Quando o download terminar, abra o '
                'arquivo e confirme a instalação. Se o Android pedir, '
                'permita instalar apps desta fonte.'
          : 'A versão ${update.latestVersion} está na App Store (você usa '
                'a ${update.currentVersion}).\n\nToque em "Atualizar" para '
                'abrir a App Store.',
      style: const TextStyle(height: 1.35),
    ),
    actionsAlignment: MainAxisAlignment.spaceBetween,
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        style: TextButton.styleFrom(foregroundColor: _ink),
        child: const Text('Depois'),
      ),
      FilledButton.icon(
        onPressed: () => unawaited(_open(context)),
        style: FilledButton.styleFrom(
          backgroundColor: _yellow,
          foregroundColor: _ink,
        ),
        icon: Icon(
          _isAndroid ? Icons.download_rounded : Icons.open_in_new_rounded,
        ),
        label: Text(
          _isAndroid ? 'Baixar' : 'Atualizar',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
    ],
  );
}
