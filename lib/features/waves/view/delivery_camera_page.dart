import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../../../core/presentation/app_messages.dart';

const _ink = Color(0xFF171713);
const _yellow = Color(0xFFF8E94E);

/// Foto confirmada na câmera interna.
class DeliveryCameraPhoto {
  const DeliveryCameraPhoto({required this.filename, required this.bytes});

  final String filename;
  final Uint8List bytes;
}

/// Câmera renderizada dentro do próprio app.
///
/// A câmera externa do sistema (image_picker) coloca o app em segundo plano e,
/// em aparelhos com pouca memória, o Android encerra o processo antes da foto
/// voltar, perdendo a tela de finalização. Aqui o app nunca sai da tela.
///
/// Cuidados de desempenho (aparelhos de entrada travavam ou fechavam o app):
/// * resolução `high` (720p) em vez de `veryHigh`: a foto de comprovante não
///   precisa de mais que isso e cada captura grande ocupava dezenas de MB;
/// * `initialize()` tem tempo limite e, se falhar, tenta uma resolução menor;
/// * a câmera só é liberada quando o app vai realmente para segundo plano
///   (não em `inactive`, que dispara até ao puxar a barra de notificações) e
///   nunca no meio de uma captura;
/// * a prévia da foto é decodificada no tamanho da tela, não no tamanho real.
class DeliveryCameraPage extends StatefulWidget {
  const DeliveryCameraPage({super.key});

  @override
  State<DeliveryCameraPage> createState() => _DeliveryCameraPageState();
}

class _DeliveryCameraPageState extends State<DeliveryCameraPage>
    with WidgetsBindingObserver {
  static const _presets = [ResolutionPreset.high, ResolutionPreset.medium];
  static const _initTimeout = Duration(seconds: 12);
  static const _busyRetryLimit = 3;
  static const _busyRetryDelay = Duration(milliseconds: 1500);

  CameraController? _controller;
  String? _error;
  bool _capturing = false;
  bool _starting = false;
  bool _releaseAfterCapture = false;
  bool _inBackground = false;
  int _generation = 0;
  int _presetIndex = 0;
  DeliveryCameraPhoto? _preview;
  FlashMode _flashMode = FlashMode.off;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    final controller = _controller;
    _controller = null;
    unawaited(_safeDispose(controller));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _inBackground = true;
        if (_capturing) {
          // Liberar a câmera durante takePicture derruba alguns aparelhos.
          _releaseAfterCapture = true;
        } else {
          _releaseCamera();
        }
      case AppLifecycleState.resumed:
        _inBackground = false;
        if (_controller == null &&
            _preview == null &&
            !_starting &&
            _error == null &&
            mounted) {
          unawaited(_initCamera());
        }
      case AppLifecycleState.inactive:
        // Diálogo de permissão, barra de notificações etc. A câmera continua.
        break;
    }
  }

  /// Remove a prévia da árvore antes de liberar o controlador, evitando que
  /// o CameraPreview desenhe uma textura já descartada.
  void _releaseCamera() {
    _generation++;
    final controller = _controller;
    if (controller == null) return;
    if (mounted) {
      setState(() => _controller = null);
    } else {
      _controller = null;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_safeDispose(controller)),
    );
  }

  static Future<void> _safeDispose(CameraController? controller) async {
    if (controller == null) return;
    try {
      await controller.dispose();
    } catch (_) {
      // Alguns drivers lançam erro ao fechar uma sessão já encerrada.
    }
  }

  Future<void> _initCamera() async {
    if (_starting) return;
    _starting = true;
    final generation = ++_generation;
    if (mounted) setState(() => _error = null);
    CameraController? controller;
    try {
      final cameras = await availableCameras().timeout(_initTimeout);
      if (cameras.isEmpty) {
        _setError('Nenhuma câmera foi encontrada neste aparelho.');
        return;
      }
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      var busyRetries = 0;
      while (true) {
        controller = CameraController(
          camera,
          _presets[_presetIndex],
          enableAudio: false,
        );
        try {
          await controller.initialize().timeout(_initTimeout);
          break;
        } on CameraException catch (error) {
          await _safeDispose(controller);
          controller = null;
          if (_isPermissionError(error)) rethrow;
          if (_isBusyError(error) && busyRetries < _busyRetryLimit) {
            // A câmera ainda está presa a outro app (ou ao leitor de
            // etiquetas) e costuma ser liberada em poucos segundos.
            busyRetries++;
            await Future<void>.delayed(_busyRetryDelay);
            if (!mounted || generation != _generation || _inBackground) {
              return;
            }
            continue;
          }
          if (_presetIndex >= _presets.length - 1) rethrow;
          _presetIndex++;
        } on TimeoutException {
          await _safeDispose(controller);
          controller = null;
          if (_presetIndex >= _presets.length - 1) rethrow;
          _presetIndex++;
        }
      }
      if (!mounted || generation != _generation || _inBackground) {
        await _safeDispose(controller);
        return;
      }
      try {
        await controller.setFlashMode(_flashMode);
      } catch (_) {
        // Aparelhos sem flash continuam funcionando normalmente.
      }
      if (!mounted || generation != _generation) {
        await _safeDispose(controller);
        return;
      }
      setState(() => _controller = controller);
    } on CameraException catch (error) {
      _setError(
        _isPermissionError(error)
            ? 'A câmera é obrigatória para registrar a foto. Permita o acesso nas configurações do telefone.'
            : _isBusyError(error)
            ? 'A câmera está sendo usada por outro aplicativo. Feche apps de câmera, chamadas de vídeo ou lanterna e toque em tentar novamente.'
            : 'Não foi possível abrir a câmera. Tente novamente.',
      );
    } on TimeoutException {
      _setError(
        'A câmera demorou para responder. Feche outros apps e tente novamente.',
      );
    } catch (_) {
      _setError('Não foi possível abrir a câmera. Tente novamente.');
    } finally {
      _starting = false;
      // O app pode ter ido e voltado do segundo plano durante a abertura;
      // nesse caso esta tentativa foi descartada e precisa ser refeita.
      if (mounted &&
          generation != _generation &&
          !_inBackground &&
          _controller == null &&
          _preview == null &&
          _error == null) {
        unawaited(_initCamera());
      }
    }
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  /// Câmera ocupada/desconectada: outro app, sessão anterior ainda fechando
  /// ou serviço de câmera do Android travado.
  static bool _isBusyError(CameraException error) {
    final text = '${error.code} ${error.description ?? ''}'.toLowerCase();
    return text.contains('in use') ||
        text.contains('in_use') ||
        text.contains('busy') ||
        text.contains('max_cameras') ||
        text.contains('maxcameras') ||
        text.contains('disconnected') ||
        text.contains('disabled') ||
        text.contains('cameraaccess') ||
        text.contains('camera_error') ||
        text.contains('error_camera');
  }

  static bool _isPermissionError(CameraException error) {
    final code = error.code.toLowerCase();
    return code.contains('denied') ||
        code.contains('permission') ||
        code.contains('restricted');
  }

  void _retry() {
    _releaseCamera();
    setState(() => _error = null);
    unawaited(_initCamera());
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (_capturing ||
        controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final file = await controller.takePicture();
      final bytes = await _compress(await file.readAsBytes());
      unawaited(_deleteTemp(file.path));
      if (!mounted) return;
      try {
        await controller.pausePreview();
      } catch (_) {
        // Pausar é só economia de bateria/memória durante a revisão.
      }
      if (!mounted) return;
      setState(
        () => _preview = DeliveryCameraPhoto(
          filename: file.name.isEmpty
              ? 'entrega_${DateTime.now().millisecondsSinceEpoch}.jpg'
              : file.name,
          bytes: bytes,
        ),
      );
    } catch (_) {
      if (mounted) {
        showAppMessage(
          context,
          'Não foi possível tirar a foto. Tente novamente.',
        );
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
      if (_releaseAfterCapture) {
        _releaseAfterCapture = false;
        if (_inBackground) _releaseCamera();
      }
    }
  }

  /// Recomprime a foto (JPEG 75, lado menor até 1280 px) antes de guardar.
  /// A câmera entrega JPEG com qualidade alta; para comprovante, 75 é
  /// indistinguível e reduz bastante o upload no 4G e o espaço da fila
  /// offline. Em qualquer falha, segue com a foto original.
  static Future<Uint8List> _compress(Uint8List original) async {
    try {
      final compressed = await FlutterImageCompress.compressWithList(
        original,
        minWidth: 1280,
        minHeight: 1280,
        quality: 75,
      );
      if (compressed.isEmpty || compressed.length >= original.length) {
        return original;
      }
      return compressed;
    } catch (_) {
      return original;
    }
  }

  static Future<void> _deleteTemp(String path) async {
    if (path.isEmpty) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final next = _flashMode == FlashMode.off ? FlashMode.auto : FlashMode.off;
    try {
      await controller.setFlashMode(next);
      if (mounted) setState(() => _flashMode = next);
    } catch (_) {
      if (mounted) {
        showAppMessage(context, 'Este aparelho não permite controlar o flash.');
      }
    }
  }

  Future<void> _retake() async {
    setState(() => _preview = null);
    final controller = _controller;
    if (controller == null) {
      if (!_starting) unawaited(_initCamera());
      return;
    }
    try {
      await controller.resumePreview();
    } catch (_) {
      if (mounted) _retry();
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      backgroundColor: Colors.black,
      body: preview != null ? _buildReview(preview) : _buildCamera(),
    );
  }

  Widget _buildCamera() {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (ready)
          _CoverPreview(controller: controller)
        else if (_error != null)
          _CameraError(message: _error!, onRetry: _retry)
        else
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _RoundIconButton(
                  tooltip: 'Cancelar',
                  icon: Icons.close_rounded,
                  onPressed: _capturing
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
                if (ready)
                  _RoundIconButton(
                    tooltip: _flashMode == FlashMode.off
                        ? 'Ativar flash automático'
                        : 'Desativar flash',
                    icon: _flashMode == FlashMode.off
                        ? Icons.flash_off_rounded
                        : Icons.flash_auto_rounded,
                    onPressed: _capturing ? null : _toggleFlash,
                  ),
              ],
            ),
          ),
        ),
        if (ready)
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: _ShutterButton(busy: _capturing, onPressed: _capture),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildReview(DeliveryCameraPhoto photo) {
    final media = MediaQuery.of(context);
    // Decodifica no tamanho da tela: uma foto 12 MP decodificada inteira
    // ocupa ~48 MB de RAM e era a principal causa de travamento.
    final cacheWidth = (media.size.width * media.devicePixelRatio).round();
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(
          photo.bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          cacheWidth: cacheWidth > 0 ? cacheWidth : null,
          filterQuality: FilterQuality.medium,
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: _retake,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white70),
                          backgroundColor: Colors.black45,
                        ),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text(
                          'Tirar outra',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop(photo),
                        style: FilledButton.styleFrom(
                          backgroundColor: _yellow,
                          foregroundColor: _ink,
                        ),
                        icon: const Icon(Icons.check_rounded),
                        label: const Text(
                          'Usar foto',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CoverPreview extends StatelessWidget {
  const _CoverPreview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.previewSize;
    if (size == null) return CameraPreview(controller);
    // previewSize vem em paisagem; o app roda em retrato.
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size.height,
          height: size.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.no_photography_outlined,
            color: Colors.white70,
            size: 44,
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onRetry,
            style: FilledButton.styleFrom(
              backgroundColor: _yellow,
              foregroundColor: _ink,
            ),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text(
              'Tentar novamente',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    ),
  );
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton.filled(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: Colors.black54,
      foregroundColor: Colors.white,
    ),
    icon: Icon(icon),
  );
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Tirar foto',
    child: GestureDetector(
      onTap: busy ? null : onPressed,
      child: Container(
        width: 78,
        height: 78,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: busy ? Colors.white54 : Colors.white,
          ),
          child: busy
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(strokeWidth: 3, color: _ink),
                )
              : null,
        ),
      ),
    ),
  );
}
