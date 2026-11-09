import 'dart:async';

import 'package:flutter/material.dart';

import '../network/offline_request_queue.dart';

const _ink = Color(0xFF171713);
const _yellow = Color(0xFFF8E94E);
const _danger = Color(0xFFB3261E);

/// Faixa no topo do app que mostra o estado das requisições guardadas sem
/// rede: quantas estão pendentes, a tentativa atual (de no máximo 3) e quando
/// será a próxima. Quando as tentativas acabam, oferece o reenvio manual.
class OfflineQueueBanner extends StatefulWidget {
  const OfflineQueueBanner({
    required this.queue,
    required this.child,
    super.key,
  });

  final OfflineRequestQueue queue;
  final Widget child;

  @override
  State<OfflineQueueBanner> createState() => _OfflineQueueBannerState();
}

class _OfflineQueueBannerState extends State<OfflineQueueBanner> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.queue.status.addListener(_onStatus);
    _onStatus();
  }

  @override
  void dispose() {
    widget.queue.status.removeListener(_onStatus);
    _ticker?.cancel();
    super.dispose();
  }

  void _onStatus() {
    final status = widget.queue.status.value;
    final needsTicker =
        status.hasPending && !status.exhausted && status.nextRetryAt != null;
    if (needsTicker && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needsTicker) {
      _ticker?.cancel();
      _ticker = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.queue.status.value;
    if (!status.hasPending) return widget.child;
    return Column(
      children: [
        _Banner(
          status: status,
          onRetry: () => unawaited(widget.queue.retryNow(manual: true)),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.status, required this.onRetry});

  final OfflineQueueStatus status;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final count = status.pendingCount;
    final items = count == 1 ? '1 envio pendente' : '$count envios pendentes';
    final String title;
    final String detail;
    if (status.sending) {
      title = 'Enviando…';
      detail = items;
    } else if (status.exhausted) {
      title = 'Sem conexão com o servidor';
      detail =
          '$items. As ${status.maxAttempts} tentativas automáticas falharam; os dados continuam salvos no aparelho.';
    } else {
      title = 'Sem conexão · $items';
      final next = status.nextRetryAt;
      final seconds = next
          ?.difference(DateTime.now())
          .inSeconds
          .clamp(0, 3600);
      final attempt = (status.attempts + 1).clamp(1, status.maxAttempts);
      detail = seconds == null
          ? 'Nova tentativa em breve.'
          : 'Tentativa $attempt de ${status.maxAttempts} em ${_format(seconds)}.';
    }
    final background = status.exhausted ? _danger : _ink;
    return Material(
      color: background,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              Icon(
                status.sending
                    ? Icons.cloud_upload_outlined
                    : Icons.cloud_off_rounded,
                color: _yellow,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      detail,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (!status.sending)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(foregroundColor: _yellow),
                  child: Text(
                    status.exhausted ? 'Tentar novamente' : 'Enviar agora',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _yellow,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _format(int seconds) {
    final minutes = seconds ~/ 60;
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }
}
