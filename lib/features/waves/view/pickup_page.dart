import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/presentation/app_messages.dart';
import '../data/pickup_label_scope.dart';
import '../data/wave_service.dart';

const _ink = Color(0xFF171713);
const _cream = Color(0xFFF5F3ED);
const _yellow = Color(0xFFF8E94E);
const _muted = Color(0xFF77746C);

class PickupPage extends StatefulWidget {
  const PickupPage({required this.service, required this.progress, super.key});

  final WaveService service;
  final PickupProgress progress;

  @override
  State<PickupPage> createState() => _PickupPageState();
}

class _PickupPageState extends State<PickupPage> {
  static const _stabilizationDuration = Duration(seconds: 1);
  static const _postScanDelay = Duration(seconds: 1);
  static const _maximumDetectionGap = Duration(milliseconds: 450);

  final _manualCodeController = TextEditingController();
  final _scannerController = MobileScannerController(
    cameraResolution: const Size(1280, 720),
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 200,
    formats: const [BarcodeFormat.qrCode, BarcodeFormat.code128],
    autoZoom: true,
  );
  late PickupProgress _progress;
  PickupLabelScope _labelGranularity = PickupLabelScope.fallback;
  bool _registering = false;
  bool _markingNotGoing = false;
  bool _landscape = false;
  String? _candidateCode;
  String? _candidateKey;
  DateTime? _candidateSince;
  DateTime? _candidateLastSeen;
  int _candidateReads = 0;
  DateTime? _nextScanAllowedAt;
  _PickupScanFeedback? _scanFeedback;
  Timer? _feedbackTimer;

  @override
  void initState() {
    super.initState();
    _progress = widget.progress;
    _labelGranularity =
        widget.progress.labelGranularity ?? PickupLabelScope.fallback;
  }

  @override
  void dispose() {
    unawaited(
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]),
    );
    _feedbackTimer?.cancel();
    _manualCodeController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_registering || _markingNotGoing || capture.barcodes.isEmpty) {
      return;
    }
    final detectedCodes = capture.barcodes
        .map((barcode) => barcode.rawValue?.trim() ?? '')
        .where((code) => code.isNotEmpty)
        .toList();
    if (detectedCodes.isEmpty) return;
    final code = _preferredDetectedCode(detectedCodes);

    final now = DateTime.now();
    if (_nextScanAllowedAt != null && now.isBefore(_nextScanAllowedAt!)) {
      return;
    }
    final key = _normalizeCode(code);

    final lostCandidate =
        _candidateLastSeen == null ||
        now.difference(_candidateLastSeen!) > _maximumDetectionGap;
    if (_candidateKey != key || lostCandidate) {
      setState(() {
        _candidateCode = code;
        _candidateKey = key;
        _candidateSince = now;
        _candidateLastSeen = now;
        _candidateReads = 1;
      });
      return;
    }

    _candidateLastSeen = now;
    _candidateReads++;
    if (_candidateReads < 3 ||
        now.difference(_candidateSince!) < _stabilizationDuration) {
      return;
    }

    setState(() {
      _candidateCode = null;
      _candidateKey = null;
      _candidateSince = null;
      _candidateLastSeen = null;
      _candidateReads = 0;
    });
    _nextScanAllowedAt = now.add(_postScanDelay);
    await _register(code);
  }

  Future<void> _register(String rawCode) async {
    final code = rawCode.trim();
    if (_registering || _markingNotGoing || code.isEmpty) {
      if (code.isEmpty) _message('Informe ou leia um código válido.');
      return;
    }

    final knownBefore = _findOrder(_progress, code);
    final knownCodeBefore = _findCode(knownBefore, code);
    final scannedBefore = {
      for (final order in _progress.orders)
        for (final label in order.codes)
          if (label.isScanned) _normalizeCode(label.code),
    };
    _nextScanAllowedAt = DateTime.now().add(_postScanDelay);
    setState(() {
      _registering = true;
      _scanFeedback = null;
    });
    try {
      try {
        await _scannerController.stop();
      } catch (_) {
        // A leitura manual pode ocorrer antes de a câmera terminar de iniciar.
      }
      final updated = await widget.service.registerPickup(
        waveId: _progress.waveId,
        code: code,
      );
      if (!mounted) return;
      setState(() {
        _progress = updated;
        _labelGranularity = updated.labelGranularity ?? _labelGranularity;
        _manualCodeController.clear();
      });
      final newlyScanned = _findNewlyScannedCode(updated, scannedBefore);
      final order =
          _findOrder(updated, code) ?? newlyScanned?.order ?? knownBefore;
      final scannedCode =
          _findCode(order, code) ?? newlyScanned?.code ?? knownCodeBefore;
      _showScanFeedback(
        _PickupScanFeedback(
          success: true,
          title: updated.isComplete
              ? 'Carga conferida por completo'
              : order?.isPickedUp == true
              ? 'Pedido conferido com sucesso'
              : 'Etiqueta conferida com sucesso',
          message: updated.isComplete
              ? 'Todos os ${updated.total} pedidos foram retirados.'
              : order != null && order.totalLabels > 1
              ? '${order.scannedLabels} de ${order.totalLabels} etiquetas deste pedido · '
                    '${updated.pending} pedido${updated.pending == 1 ? '' : 's'} pendente${updated.pending == 1 ? '' : 's'}'
              : '${updated.pickedUp} de ${updated.total} pedidos retirados · '
                    '${updated.pending} pendentes',
          orderNumber: order?.orderNumber ?? '',
          customer: order?.customer ?? '',
          code: scannedCode?.code ?? code,
        ),
      );
    } on WaveServiceException catch (error) {
      if (mounted) {
        var displayOrder = knownBefore;
        var displayCode = knownCodeBefore;
        var alreadyScanned = knownCodeBefore?.isScanned == true;
        if (!alreadyScanned && _isAlreadyScannedMessage(error.message)) {
          try {
            final refreshed = await widget.service.getPickupProgress(
              _progress.waveId,
            );
            if (mounted) setState(() => _progress = refreshed);
            displayOrder = _findOrder(refreshed, code) ?? displayOrder;
            displayCode = _findCode(displayOrder, code) ?? displayCode;
            alreadyScanned = displayCode?.isScanned == true;
          } catch (_) {
            // Sem confirmação da API, a resposta continua sendo tratada como erro.
          }
        }
        _showScanFeedback(
          _PickupScanFeedback(
            success: false,
            warning: alreadyScanned,
            title: alreadyScanned
                ? 'Etiqueta já conferida'
                : 'Não foi possível conferir',
            message: alreadyScanned
                ? 'Esta etiqueta já consta na conferência da carga.'
                : error.message,
            orderNumber: displayOrder?.orderNumber ?? '',
            customer: displayOrder?.customer ?? '',
            code: displayCode?.code ?? code,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        _showScanFeedback(
          _PickupScanFeedback(
            success: false,
            title: 'Falha ao conferir a etiqueta',
            message: 'Verifique a conexão e tente ler o código novamente.',
            orderNumber: knownBefore?.orderNumber ?? '',
            customer: knownBefore?.customer ?? '',
            code: knownCodeBefore?.code ?? code,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _registering = false);
        await _resumeScanner();
      }
    }
  }

  String _normalizeCode(String code) => normalizePickupCode(code);

  String _preferredDetectedCode(List<String> detectedCodes) {
    final candidateKey = _candidateKey;
    if (candidateKey != null) {
      for (final code in detectedCodes) {
        if (_normalizeCode(code) == candidateKey) return code;
      }
    }
    for (final code in detectedCodes) {
      final order = _findOrder(_progress, code);
      final label = _findCode(order, code);
      if (label != null && !label.isScanned) return code;
    }
    for (final code in detectedCodes) {
      if (_findOrder(_progress, code) != null) return code;
    }
    return detectedCodes.first;
  }

  bool _isAlreadyScannedMessage(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('já retirado') ||
        normalized.contains('ja retirado') ||
        normalized.contains('já foi retirado') ||
        normalized.contains('ja foi retirado') ||
        normalized.contains('já foi lido') ||
        normalized.contains('ja foi lido') ||
        normalized.contains('volume já lido') ||
        normalized.contains('volume ja lido') ||
        normalized.contains('etiqueta já lida') ||
        normalized.contains('etiqueta ja lida') ||
        normalized.contains('already picked') ||
        normalized.contains('already collected') ||
        normalized.contains('already scanned');
  }

  PickupOrder? _findOrder(PickupProgress progress, String code) {
    for (final order in progress.orders) {
      if (order.matchesCode(code)) return order;
    }
    return null;
  }

  PickupCode? _findCode(PickupOrder? order, String code) {
    if (order == null) return null;
    final key = _normalizeCode(code);
    for (final label in order.codes) {
      if (_normalizeCode(label.code) == key) return label;
    }
    return null;
  }

  _ScannedPickup? _findNewlyScannedCode(
    PickupProgress progress,
    Set<String> scannedBefore,
  ) {
    for (final order in progress.orders) {
      for (final label in order.codes) {
        if (label.isScanned &&
            !scannedBefore.contains(_normalizeCode(label.code))) {
          return _ScannedPickup(order, label);
        }
      }
    }
    return null;
  }

  void _showScanFeedback(_PickupScanFeedback feedback) {
    _feedbackTimer?.cancel();
    if (!mounted) return;
    setState(() => _scanFeedback = feedback);
    _feedbackTimer = Timer(appMessageDuration, () {
      if (mounted) setState(() => _scanFeedback = null);
    });
  }

  void _message(String text) {
    showAppMessage(context, text);
  }

  Future<void> _toggleOrientation() async {
    final landscape = !_landscape;
    await SystemChrome.setPreferredOrientations(
      landscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
    if (mounted) setState(() => _landscape = landscape);
  }

  Future<void> _pauseScanner() async {
    try {
      await _scannerController.stop();
    } catch (_) {
      // A camera pode ainda nem ter terminado de iniciar; seguir e seguro.
    }
  }

  Future<void> _resumeScanner() async {
    if (_progress.isComplete) return;
    final nextScanAllowedAt = _nextScanAllowedAt;
    if (nextScanAllowedAt != null) {
      final remaining = nextScanAllowedAt.difference(DateTime.now());
      if (!remaining.isNegative) await Future<void>.delayed(remaining);
    }
    if (!mounted || _progress.isComplete) return;
    try {
      await _scannerController.start();
    } catch (_) {
      // As acoes manuais continuam disponiveis se a camera nao reiniciar.
    }
  }

  Future<void> _openOrders() async {
    await _pauseScanner();
    if (!mounted) return;
    final order = await Navigator.of(context).push<PickupOrder>(
      MaterialPageRoute<PickupOrder>(
        fullscreenDialog: true,
        builder: (_) => _PickupOrdersPage(progress: _progress),
      ),
    );
    if (!mounted) return;
    if (order != null) {
      await _markNotGoing(order);
      if (!mounted) return;
    }
    await _resumeScanner();
  }

  Future<void> _markNotGoing(PickupOrder order) async {
    if (_markingNotGoing) return;
    setState(() {
      _markingNotGoing = true;
      _scanFeedback = null;
    });
    try {
      final updated = await widget.service.markOrderNotGoing(
        waveId: _progress.waveId,
        orderId: order.orderId,
      );
      if (!mounted) return;
      setState(() => _progress = updated);
      _showScanFeedback(
        _PickupScanFeedback(
          success: true,
          title: 'Pedido marcado como "não vai"',
          message: updated.isComplete
              ? 'A carga está liberada: o restante já foi conferido.'
              : 'O pedido saiu desta carga e o que faltou virou uma nota nova '
                    'para nova roteirização.',
          orderNumber: order.orderNumber,
          customer: order.customer,
          code: '',
        ),
      );
    } on WaveServiceException catch (error) {
      if (!mounted) return;
      _showScanFeedback(
        _PickupScanFeedback(
          success: false,
          title: 'Não foi possível marcar "não vai"',
          message: error.message,
          orderNumber: order.orderNumber,
          customer: order.customer,
          code: '',
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _showScanFeedback(
        _PickupScanFeedback(
          success: false,
          title: 'Não foi possível marcar "não vai"',
          message: 'Verifique a conexão e tente novamente.',
          orderNumber: order.orderNumber,
          customer: order.customer,
          code: '',
        ),
      );
    } finally {
      if (mounted) setState(() => _markingNotGoing = false);
    }
  }

  Future<void> _openManualCode() async {
    try {
      await _scannerController.stop();
    } catch (_) {
      // A entrada manual funciona mesmo antes da câmera terminar de iniciar.
    }
    if (!mounted) return;
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => _ManualPickupCodePage(
          controller: _manualCodeController,
          barcodeSource: _progress.barcodeSource,
          labelGranularity: _labelGranularity,
        ),
      ),
    );
    if (!mounted) return;
    if (code != null && code.trim().isNotEmpty) {
      await _register(code);
      return;
    }
    await _resumeScanner();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: _FullscreenScanner(
      controller: _scannerController,
      progress: _progress,
      labelGranularity: _labelGranularity,
      landscape: _landscape,
      registering: _registering,
      busy: _registering || _markingNotGoing,
      candidateCode: _candidateCode,
      scanFeedback: _scanFeedback,
      onDetect: _onDetect,
      onClose: () => Navigator.of(context).pop(false),
      onRotate: _toggleOrientation,
      onOrders: _openOrders,
      onManualCode: _openManualCode,
      onComplete: () => Navigator.of(context).pop(true),
    ),
  );
}

class _FullscreenScanner extends StatelessWidget {
  const _FullscreenScanner({
    required this.controller,
    required this.progress,
    required this.labelGranularity,
    required this.landscape,
    required this.registering,
    required this.busy,
    required this.candidateCode,
    required this.scanFeedback,
    required this.onDetect,
    required this.onClose,
    required this.onRotate,
    required this.onOrders,
    required this.onManualCode,
    required this.onComplete,
  });

  final MobileScannerController controller;
  final PickupProgress progress;
  final PickupLabelScope labelGranularity;
  final bool landscape;
  final bool registering;
  final bool busy;
  final String? candidateCode;
  final _PickupScanFeedback? scanFeedback;
  final ValueChanged<BarcodeCapture> onDetect;
  final VoidCallback onClose;
  final VoidCallback onRotate;
  final VoidCallback onOrders;
  final VoidCallback onManualCode;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(controller: controller, onDetect: onDetect),
        if (!progress.isComplete)
          Align(
            alignment: const Alignment(0, .28),
            child: _ScannerStabilityHint(candidateCode: candidateCode),
          ),
        SafeArea(
          child: Stack(
            children: [
              Positioned(
                left: 12,
                top: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ScannerProgressPill(progress: progress),
                    const SizedBox(height: 6),
                    _LabelScopePill(scope: labelGranularity),
                  ],
                ),
              ),
              Positioned(
                right: 12,
                top: 8,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _CameraFloatingButton(
                      tooltip: 'Fechar retirada',
                      icon: Icons.close_rounded,
                      onPressed: registering ? null : onClose,
                    ),
                    const SizedBox(height: 8),
                    _CameraFloatingButton(
                      tooltip: 'Ligar ou desligar flash',
                      icon: Icons.flashlight_on_rounded,
                      onPressed: registering || progress.isComplete
                          ? null
                          : controller.toggleTorch,
                    ),
                    const SizedBox(height: 8),
                    _CameraFloatingButton(
                      tooltip: landscape ? 'Usar tela em pé' : 'Virar a tela',
                      icon: landscape
                          ? Icons.stay_current_portrait_rounded
                          : Icons.screen_rotation_alt_rounded,
                      onPressed: registering ? null : onRotate,
                    ),
                    const SizedBox(height: 8),
                    _CameraFloatingButton(
                      tooltip: 'Pedidos da carga',
                      icon: Icons.fact_check_outlined,
                      onPressed: busy ? null : onOrders,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (progress.isComplete)
          Container(
            color: Colors.black.withValues(alpha: .66),
            alignment: Alignment.center,
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_rounded, size: 68, color: _yellow),
                SizedBox(height: 10),
                Text(
                  'Carga conferida',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        if (scanFeedback != null && !busy)
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 82),
                child: _PickupScanFeedbackCard(feedback: scanFeedback!),
              ),
            ),
          ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: progress.isComplete
                  ? _ScannerBottomButton(
                      icon: Icons.check_circle_rounded,
                      label: 'Concluir retirada',
                      onPressed: onComplete,
                    )
                  : _ScannerBottomButton(
                      icon: Icons.keyboard_rounded,
                      label: 'Digitar código manualmente',
                      onPressed: busy ? null : onManualCode,
                    ),
            ),
          ),
        ),
        if (busy)
          Container(
            color: Colors.black.withValues(alpha: .58),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: _yellow),
                const SizedBox(height: 16),
                Text(
                  registering
                      ? 'Conferindo etiqueta...'
                      : 'Atualizando a carga...',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _PickupScanFeedback {
  const _PickupScanFeedback({
    required this.success,
    this.warning = false,
    required this.title,
    required this.message,
    required this.orderNumber,
    required this.customer,
    required this.code,
  });

  final bool success;
  final bool warning;
  final String title;
  final String message;
  final String orderNumber;
  final String customer;
  final String code;
}

class _ScannedPickup {
  const _ScannedPickup(this.order, this.code);

  final PickupOrder order;
  final PickupCode code;
}

class _ScannerStabilityHint extends StatelessWidget {
  const _ScannerStabilityHint({required this.candidateCode});

  final String? candidateCode;

  @override
  Widget build(BuildContext context) {
    final reading = candidateCode != null;
    return Container(
      constraints: const BoxConstraints(maxWidth: 310),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            reading
                ? Icons.center_focus_strong_rounded
                : Icons.qr_code_scanner_rounded,
            size: 19,
            color: _yellow,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              reading
                  ? 'Mantenha parado por 1 segundo · $candidateCode'
                  : 'Leia QR Code ou código de barras em toda a tela',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickupScanFeedbackCard extends StatelessWidget {
  const _PickupScanFeedbackCard({required this.feedback});

  final _PickupScanFeedback feedback;

  @override
  Widget build(BuildContext context) {
    final accent = feedback.warning
        ? const Color(0xFF7A5700)
        : feedback.success
        ? const Color(0xFF137A42)
        : const Color(0xFFB42318);
    final background = feedback.warning
        ? const Color(0xFFFFF1B8)
        : feedback.success
        ? const Color(0xFFE9F8EF)
        : const Color(0xFFFFECEA);
    return Material(
      color: background,
      elevation: 12,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: EdgeInsets.all(feedback.warning ? 11 : 15),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              feedback.warning
                  ? Icons.warning_amber_rounded
                  : feedback.success
                  ? Icons.check_circle_rounded
                  : Icons.error_rounded,
              color: accent,
              size: feedback.warning ? 24 : 30,
            ),
            SizedBox(width: feedback.warning ? 9 : 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    feedback.title,
                    style: TextStyle(
                      color: accent,
                      fontSize: feedback.warning ? 14 : 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (feedback.orderNumber.isNotEmpty ||
                      feedback.customer.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      [
                        if (feedback.orderNumber.isNotEmpty)
                          'Pedido ${feedback.orderNumber}',
                        if (feedback.customer.isNotEmpty) feedback.customer,
                      ].join(' · '),
                      maxLines: feedback.warning ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                  if (feedback.code.isNotEmpty && !feedback.warning) ...[
                    const SizedBox(height: 3),
                    Text(
                      'Código: ${feedback.code}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  if (!feedback.warning ||
                      (feedback.orderNumber.isEmpty &&
                          feedback.customer.isEmpty)) ...[
                    const SizedBox(height: 4),
                    Text(
                      feedback.message,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraFloatingButton extends StatelessWidget {
  const _CameraFloatingButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: _ink,
      disabledBackgroundColor: Colors.white.withValues(alpha: .45),
      minimumSize: const Size(42, 42),
      maximumSize: const Size(42, 42),
      iconSize: 21,
      elevation: 6,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    icon: Icon(icon),
  );
}

class _ScannerProgressPill extends StatelessWidget {
  const _ScannerProgressPill({required this.progress});
  final PickupProgress progress;

  @override
  Widget build(BuildContext context) {
    final label = progress.totalLabels > 0
        ? '${progress.scannedLabels}/${progress.totalLabels} etiquetas'
        : '${progress.pickedUp}/${progress.total} pedidos';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _yellow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _LabelScopePill extends StatelessWidget {
  const _LabelScopePill({required this.scope});

  final PickupLabelScope scope;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: .72),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.label_outline_rounded, size: 15, color: _yellow),
        const SizedBox(width: 6),
        Text(
          'Etiqueta: ${scope.shortLabel}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

/// Lista os pedidos da carga durante a conferencia.
///
/// Devolve o pedido que o entregador marcou como "nao vai" para a tela do
/// scanner concluir a chamada na API.
class _PickupOrdersPage extends StatelessWidget {
  const _PickupOrdersPage({required this.progress});

  final PickupProgress progress;

  Future<void> _confirmNotGoing(BuildContext context, PickupOrder order) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _cream,
        title: const Text(
          'Marcar como "não vai"?',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        content: Text(
          'O pedido ${order.orderNumber} sai desta carga e o que faltou vira '
          'uma nota nova, para ser roteirizada depois. A conferência já feita '
          'neste pedido é perdida.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB42318),
              foregroundColor: Colors.white,
            ),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      Navigator.of(context).pop(order);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _cream,
    appBar: AppBar(
      backgroundColor: _cream,
      surfaceTintColor: _cream,
      foregroundColor: _ink,
      title: const Text(
        'Pedidos da carga',
        style: TextStyle(fontWeight: FontWeight.w900),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text(
          '${progress.pickedUp} de ${progress.total} pedidos retirados · '
          '${progress.scannedLabels} de ${progress.totalLabels} etiquetas',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
        const SizedBox(height: 14),
        if (progress.orders.isEmpty)
          const Text(
            'Nenhum pedido nesta conferência.',
            style: TextStyle(color: _muted, fontSize: 13),
          )
        else
          ...progress.orders.map(
            (order) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _PickupOrderCard(
                order: order,
                onNotGoing: order.isPickedUp
                    ? null
                    : () => _confirmNotGoing(context, order),
              ),
            ),
          ),
      ],
    ),
  );
}

class _PickupOrderCard extends StatelessWidget {
  const _PickupOrderCard({required this.order, required this.onNotGoing});

  final PickupOrder order;
  final VoidCallback? onNotGoing;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFE4E1D8)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              order.isPickedUp
                  ? Icons.check_circle_rounded
                  : Icons.inventory_2_outlined,
              size: 22,
              color: order.isPickedUp ? const Color(0xFF238636) : _muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.orderNumber.isEmpty
                        ? 'Pedido #${order.orderId}'
                        : order.orderNumber,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    order.customer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            Text(
              order.isPickedUp
                  ? 'Retirado'
                  : '${order.scannedLabels}/${order.totalLabels} etiquetas',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
            ),
          ],
        ),
        if (onNotGoing != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onNotGoing,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFB42318),
                side: const BorderSide(color: Color(0xFFF0C2BD)),
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.block_rounded, size: 18),
              label: const Text(
                'Não vai',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class _ScannerBottomButton extends StatelessWidget {
  const _ScannerBottomButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: _ink,
      disabledBackgroundColor: Colors.white.withValues(alpha: .45),
      minimumSize: const Size.fromHeight(48),
    ),
    icon: Icon(icon, size: 20),
    label: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w900),
    ),
  );
}

class _ManualPickupCodePage extends StatelessWidget {
  const _ManualPickupCodePage({
    required this.controller,
    required this.barcodeSource,
    required this.labelGranularity,
  });

  final TextEditingController controller;
  final String barcodeSource;
  final PickupLabelScope labelGranularity;

  void _submit(BuildContext context) {
    final code = controller.text.trim();
    if (code.isEmpty) {
      showAppMessage(context, 'Digite um código para continuar.');
      return;
    }
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: true,
    backgroundColor: _cream,
    body: SafeArea(
      child: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                82,
                20,
                MediaQuery.viewInsetsOf(context).bottom + 24,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: math.max(
                    0,
                    MediaQuery.sizeOf(context).height -
                        MediaQuery.paddingOf(context).vertical -
                        MediaQuery.viewInsetsOf(context).bottom -
                        106,
                  ),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: _ManualCodeCard(
                      controller: controller,
                      barcodeSource: barcodeSource,
                      labelGranularity: labelGranularity,
                      registering: false,
                      onSubmit: () => _submit(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 14,
            top: 10,
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: _ink,
                elevation: 4,
                shadowColor: const Color(0x55171713),
                side: const BorderSide(color: Color(0x22171713)),
                minimumSize: const Size(112, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: const Icon(Icons.close_rounded),
              label: const Text(
                'Fechar',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ManualCodeCard extends StatelessWidget {
  const _ManualCodeCard({
    required this.controller,
    required this.barcodeSource,
    required this.labelGranularity,
    required this.registering,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final String barcodeSource;
  final PickupLabelScope labelGranularity;
  final bool registering;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(19),
      border: Border.all(color: const Color(0xFFE4E1D8)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: _yellow,
              borderRadius: BorderRadius.circular(19),
            ),
            child: const Icon(Icons.keyboard_rounded, size: 30),
          ),
        ),
        const SizedBox(height: 15),
        const Center(
          child: Text(
            'Digite o código da etiqueta',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            barcodeSource == 'external_id'
                ? 'Use o código externo exatamente como aparece na etiqueta.'
                : 'Use o código completo exatamente como aparece na etiqueta.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ),
        if (labelGranularity != PickupLabelScope.volume) ...[
          const SizedBox(height: 6),
          Center(
            child: Text(
              labelGranularity.description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _ink,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        TextField(
          controller: controller,
          autofocus: true,
          enabled: !registering,
          textAlign: TextAlign.center,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmit(),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          decoration: InputDecoration(
            hintText: barcodeSource == 'external_id'
                ? 'Código externo da etiqueta'
                : 'Código da etiqueta',
            filled: true,
            fillColor: _cream,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: registering ? null : onSubmit,
            style: FilledButton.styleFrom(
              backgroundColor: _ink,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.check_rounded),
            label: const Text(
              'Confirmar código',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ],
    ),
  );
}
