import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

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
class DeliveryCameraPage extends StatefulWidget {
  const DeliveryCameraPage({super.key});

  @override
  State<DeliveryCameraPage> createState() => _DeliveryCameraPageState();
}

class _DeliveryCameraPageState extends State<DeliveryCameraPage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initializing;
  String? _error;
  bool _capturing = false;
  bool _starting = false;
  DeliveryCameraPhoto? _preview;
  FlashMode _flashMode = FlashMode.off;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializing = _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // O controlador precisa ser liberado ao sair do app e recriado ao voltar,
    // senão a câmera fica presa ou lança erro no retorno.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final controller = _controller;
      if (controller == null) return;
      _controller = null;
      unawaited(controller.dispose());
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      // O pedido de permissão também deixa o app inativo; não reinicia em dobro.
      if (_controller == null && _preview == null && !_starting && mounted) {
        setState(() => _initializing = _initCamera());
      }
    }
  }

  Future<void> _initCamera() async {
    if (_starting) return;
    _starting = true;
    _error = null;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _setError('Nenhuma câmera foi encontrada neste aparelho.');
        return;
      }
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      try {
        await controller.setFlashMode(_flashMode);
      } catch (_) {
        // Aparelhos sem flash continuam funcionando normalmente.
      }
      final previous = _controller;
      setState(() => _controller = controller);
      await previous?.dispose();
    } on CameraException catch (error) {
      _setError(_cameraErrorMessage(error));
    } catch (_) {
      _setError('Não foi possível abrir a câmera. Tente novamente.');
    } finally {
      _starting = false;
    }
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  String _cameraErrorMessage(CameraException error) {
    final code = error.code.toLowerCase();
    if (code.contains('denied') ||
        code.contains('permission') ||
        code.contains('restricted')) {
      return 'A câmera é obrigatória para registrar a foto. Permita o acesso nas configurações do telefone.';
    }
    return 'Não foi possível abrir a câmera. Tente novamente.';
  }

  void _retry() {
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose());
    setState(() => _initializing = _initCamera());
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
      final bytes = await file.readAsBytes();
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
        showAppMessage(context, 'Não foi possível tirar a foto. Tente novamente.');
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
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

  void _retake() {
    setState(() => _preview = null);
    if (_controller == null) _retry();
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
          FutureBuilder<void>(
            future: _initializing,
            builder: (context, _) => const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
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
                child: _ShutterButton(
                  busy: _capturing,
                  onPressed: _capture,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildReview(DeliveryCameraPhoto photo) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(photo.bytes, fit: BoxFit.contain, gaplessPlayback: true),
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
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: _ink,
                  ),
                )
              : null,
        ),
      ),
    ),
  );
}
