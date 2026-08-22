import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
  final _manualCodeController = TextEditingController();
  final _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  late PickupProgress _progress;
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    _progress = widget.progress;
  }

  @override
  void dispose() {
    _manualCodeController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_registering || capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue?.trim() ?? '';
    if (code.isNotEmpty) await _register(code);
  }

  Future<void> _register(String rawCode) async {
    final code = rawCode.trim();
    if (_registering || code.isEmpty) {
      if (code.isEmpty) _message('Informe ou leia um código válido.');
      return;
    }

    setState(() => _registering = true);
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
        _manualCodeController.clear();
      });
      _message(
        updated.isComplete
            ? 'Carga conferida por completo.'
            : 'Pedido conferido. Faltam ${updated.pending}.',
      );
    } on WaveServiceException catch (error) {
      if (mounted) _message(error.message);
    } catch (_) {
      if (mounted) _message('Não foi possível registrar esta retirada.');
    } finally {
      if (mounted) {
        setState(() => _registering = false);
        if (!_progress.isComplete) {
          try {
            await _scannerController.start();
          } catch (_) {
            // A entrada manual continua disponível se a câmera não iniciar.
          }
        }
      }
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _cream,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      title: const Text(
        'Retirada da carga',
        style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 110),
      children: [
        _PickupSummary(progress: _progress),
        const SizedBox(height: 16),
        if (!_progress.isComplete) ...[
          _ScannerCard(
            controller: _scannerController,
            registering: _registering,
            onDetect: _onDetect,
          ),
          const SizedBox(height: 16),
          _ManualCodeCard(
            controller: _manualCodeController,
            barcodeSource: _progress.barcodeSource,
            registering: _registering,
            onSubmit: () => _register(_manualCodeController.text),
          ),
          const SizedBox(height: 20),
        ],
        Row(
          children: [
            const Expanded(
              child: Text(
                'Pedidos da carga',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            Text(
              '${_progress.pickedUp}/${_progress.total}',
              style: const TextStyle(
                color: _muted,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_progress.orders.isEmpty)
          const _EmptyOrders()
        else
          ..._progress.orders.map(
            (order) => Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: _PickupOrderCard(order: order),
            ),
          ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Container(
        color: _cream,
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
        child: SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: _progress.isComplete
                ? () => Navigator.of(context).pop(true)
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: _ink,
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFFD9D7D0),
              disabledForegroundColor: const Color(0xFF89867E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(17),
              ),
            ),
            icon: Icon(
              _progress.isComplete
                  ? Icons.check_circle_rounded
                  : Icons.inventory_2_outlined,
            ),
            label: Text(
              _progress.isComplete
                  ? 'Continuar para roteirização'
                  : 'Faltam ${_progress.pending} pedidos',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PickupSummary extends StatelessWidget {
  const _PickupSummary({required this.progress});

  final PickupProgress progress;

  @override
  Widget build(BuildContext context) {
    final value = progress.total == 0
        ? 0.0
        : progress.pickedUp / progress.total;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _yellow,
        borderRadius: BorderRadius.circular(23),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _ink,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  progress.isComplete
                      ? Icons.inventory_rounded
                      : Icons.qr_code_scanner_rounded,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      progress.isComplete
                          ? 'Carga conferida'
                          : 'Confira todos os pedidos',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${progress.pickedUp} retirados · ${progress.pending} pendentes',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '${(value * 100).round()}%',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: LinearProgressIndicator(
              value: value.clamp(0, 1),
              minHeight: 8,
              color: _ink,
              backgroundColor: Colors.white.withValues(alpha: .65),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScannerCard extends StatelessWidget {
  const _ScannerCard({
    required this.controller,
    required this.registering,
    required this.onDetect,
  });

  final MobileScannerController controller;
  final bool registering;
  final ValueChanged<BarcodeCapture> onDetect;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Leia a etiqueta',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: SizedBox(
          height: 245,
          child: Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(controller: controller, onDetect: onDetect),
              Center(
                child: Container(
                  width: 255,
                  height: 105,
                  decoration: BoxDecoration(
                    border: Border.all(color: _yellow, width: 3),
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
              Positioned(
                right: 10,
                top: 10,
                child: IconButton.filled(
                  tooltip: 'Ligar ou desligar flash',
                  onPressed: registering ? null : controller.toggleTorch,
                  style: IconButton.styleFrom(
                    backgroundColor: _ink.withValues(alpha: .82),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.flashlight_on_rounded),
                ),
              ),
              if (registering)
                Container(
                  color: Colors.black.withValues(alpha: .5),
                  alignment: Alignment.center,
                  child: const CircularProgressIndicator(color: _yellow),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _ManualCodeCard extends StatelessWidget {
  const _ManualCodeCard({
    required this.controller,
    required this.barcodeSource,
    required this.registering,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final String barcodeSource;
  final bool registering;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(19),
      border: Border.all(color: const Color(0xFFE4E1D8)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Digitar código manualmente',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 4),
        Text(
          barcodeSource == 'external_id'
              ? 'Use o código externo impresso na etiqueta.'
              : 'Use o número do pedido impresso na etiqueta.',
          style: const TextStyle(color: _muted, fontSize: 10),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          enabled: !registering,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmit(),
          decoration: InputDecoration(
            hintText: barcodeSource == 'external_id'
                ? 'Código externo'
                : 'Número do pedido',
            filled: true,
            fillColor: _cream,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              tooltip: 'Confirmar código',
              onPressed: registering ? null : onSubmit,
              icon: const Icon(Icons.arrow_forward_rounded),
            ),
          ),
        ),
      ],
    ),
  );
}

class _PickupOrderCard extends StatelessWidget {
  const _PickupOrderCard({required this.order});

  final PickupOrder order;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: const Color(0xFFE4E1D8)),
    ),
    child: Row(
      children: [
        Container(
          width: 39,
          height: 39,
          decoration: BoxDecoration(
            color: order.isPickedUp
                ? const Color(0xFFE9F6E7)
                : const Color(0xFFF0EEE8),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            order.isPickedUp
                ? Icons.check_circle_rounded
                : Icons.inventory_2_outlined,
            color: order.isPickedUp ? const Color(0xFF238636) : _muted,
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                order.orderNumber,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 2),
              Text(
                order.customer,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted, fontSize: 10),
              ),
              if (order.code.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  order.code,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ],
          ),
        ),
        Text(
          order.isPickedUp ? 'Retirado' : 'Pendente',
          style: TextStyle(
            color: order.isPickedUp ? const Color(0xFF238636) : _muted,
            fontSize: 9,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    ),
  );
}

class _EmptyOrders extends StatelessWidget {
  const _EmptyOrders();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
    ),
    child: const Row(
      children: [
        Icon(Icons.inventory_2_outlined, color: _muted),
        SizedBox(width: 9),
        Expanded(child: Text('Nenhum pedido retornado para conferência.')),
      ],
    ),
  );
}
